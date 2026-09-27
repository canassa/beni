//! What a message about a recursive group says, read syntactically off the
//! Bir (checker-v2.md §10.6, §10.7 R7-2, §10.8), so that it is a function of
//! the program and never of the declaration order: which members produced
//! the values a refused use names (D14's hint), and a cycle through a merged
//! group. Error paths only; split out of `Recursion.zig` (R7's review, S4).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Groups = @import("Groups.zig");
const Decl = @import("constrain/Decl.zig");

const Symbol = InternPool.Symbol;
const Error = Allocator.Error;

/// D14's hint (§10.7) for a mismatch at `region` in declaration `decl`,
/// `call` the call it is an argument of (if any), once `decl`'s merge class
/// is final: the members that produced what the refused use names, else
/// every unannotated member of the class, sorted by text. Allocated with
/// `gpa`.
pub fn hintText(gs: *Groups, decl: u32, region: Bir.Inst.Index, call: Bir.Inst.OptionalIndex) Error![]u8 {
    const cx = gs.cx;
    const bir = cx.bir;
    const scratch = cx.scratch;
    const interner = cx.interner;
    const class = try classOf(gs, decl);
    defer scratch.free(class);
    var producers: std.ArrayList(u32) = .empty;
    defer producers.deinit(scratch);
    var via: ?u32 = null;
    try producersOf(gs, decl, region, call, class, &producers, &via);

    var out: std.Io.Writer.Allocating = .init(cx.gpa);
    defer out.deinit();
    const w = &out.writer;
    if (producers.items.len == 1) {
        const p = producers.items[0];
        const name = interner.slice(bir.symbol(bir.decls[p].name));
        if (via) |local| {
            w.print("\nHint: `{s}` comes from `{s}`", .{ localName(bir, interner, local), name }) catch return error.OutOfMemory;
        } else {
            w.print("\nHint: this comes from `{s}`", .{name}) catch return error.OutOfMemory;
        }
        w.writeAll(", which is in a recursive group with ") catch return error.OutOfMemory;
        try names(w, bir, interner, class, p);
        w.print(
            \\, so its type is not known here yet.
            \\Annotate `{s}` and each use can instantiate it.
            \\
        , .{name}) catch return error.OutOfMemory;
    } else {
        w.writeAll("\nHint: this comes from a recursive group (") catch return error.OutOfMemory;
        try names(w, bir, interner, class, null);
        w.writeAll("), so its type is not known here yet.\nAnnotate ") catch return error.OutOfMemory;
        try names(w, bir, interner, class, null);
        w.writeAll(" and each use can instantiate it.\n") catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// The declaration whose instructions hold `inst`, or null. A linear scan: an
/// error path, once per D14 mismatch.
pub fn declOf(bir: *const Bir, inst: Bir.Inst.Index) ?u32 {
    for (bir.decls, 0..) |d, i| {
        if (inst.int() >= d.inst_start.int() and inst.int() < d.inst_end.int()) return @intCast(i);
    }
    return null;
}

/// Every unannotated member of `class` but `except`, sorted by text,
/// written `` `a`, `b` ``.
fn names(w: *std.Io.Writer, bir: *const Bir, interner: *const InternPool.Global, class: []const u32, except: ?u32) Error!void {
    var first = true;
    for (class) |d| {
        if (except == d or bir.decls[d].annotation != .none) continue;
        if (!first) w.writeAll(", ") catch return error.OutOfMemory;
        first = false;
        w.print("`{s}`", .{interner.slice(bir.symbol(bir.decls[d].name))}) catch return error.OutOfMemory;
    }
}

fn localName(bir: *const Bir, interner: *const InternPool.Global, local: u32) []const u8 {
    const sym = bir.locals[local].name.unwrap() orelse return "it";
    return interner.slice(bir.symbols[sym]);
}

/// The value declarations of `decl`'s merge class — its value SCC and every
/// group merged with it — sorted by name text.
pub fn classOf(gs: *Groups, decl: u32) Error![]u32 {
    const cx = gs.cx;
    const bir = cx.bir;
    var out: std.ArrayList(u32) = .empty;
    const g = gs.group_of[decl];
    if (g == Groups.none) {
        try out.append(cx.scratch, decl);
        return out.toOwnedSlice(cx.scratch);
    }
    const r = gs.root(g);
    for (gs.group_of, 0..) |dg, d| {
        if (dg == Groups.none or !bir.decls[d].kind.isValue()) continue;
        if (gs.root(dg) == r) try out.append(cx.scratch, @intCast(d));
    }
    const Ctx = struct {
        bir: *const Bir,
        interner: *const InternPool.Global,
        fn lessThan(c: @This(), a: u32, b: u32) bool {
            return std.mem.lessThan(u8, c.interner.slice(c.bir.symbol(c.bir.decls[a].name)), c.interner.slice(c.bir.symbol(c.bir.decls[b].name)));
        }
    };
    std.mem.sort(u32, out.items, Ctx{ .bir = bir, .interner = cx.interner }, Ctx.lessThan);
    return out.toOwnedSlice(cx.scratch);
}

/// The members of `class` whose references produced the values the context
/// of `origin` (in declaration `decl`) names: the body of the innermost
/// `let` function around it, or `origin` itself; a local is followed to its
/// definition, or to the `case` scrutinee or `let` value it destructures.
/// `via` is the one local of the context those producers came through, if
/// they came through exactly one and none was referenced directly.
/// The members of `class` whose references produced the values the refused
/// use names (§10.7, R7-2): its context is the body of the `let` function
/// the use calls when the mismatch is one of its arguments (`q "s"` names
/// `q`'s body), else the innermost `let` function around `region`, else
/// `region` itself; the members referenced there, by value or by a method
/// call of a member's name, and through each local it names, followed to its
/// definition or to the `case` scrutinee or `let` value it destructures.
/// `via` is the one local those producers came through, when they came
/// through exactly one and none was referenced directly. Sorted, unique.
fn producersOf(gs: *Groups, decl: u32, region: Bir.Inst.Index, call: Bir.Inst.OptionalIndex, class: []const u32, out: *std.ArrayList(u32), via: *?u32) Error!void {
    const cx = gs.cx;
    const bir = cx.bir;
    const scratch = cx.scratch;
    var body: Body = try .init(bir, scratch, decl);
    defer body.deinit(scratch);
    const ctx = body.calledFunction(call) orelse body.enclosingFunction(region) orelse region;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(scratch);
    // The context itself, not following its locals: its direct references
    // and the locals it names, in source order.
    var direct: std.ArrayList(u32) = .empty;
    defer direct.deinit(scratch);
    try body.refs(ctx, class, out, &direct);
    std.mem.sort(u32, direct.items, {}, std.sort.asc(u32));
    const direct_members = out.items.len;
    var through: ?u32 = null;
    var sources: usize = 0;
    var previous: ?u32 = null;
    for (direct.items) |local| {
        if (previous == local) continue;
        previous = local;
        const before = out.items.len;
        try body.follow(local, class, out, &seen);
        if (out.items.len != before) {
            sources += 1;
            through = local;
        }
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (out.items) |d| {
        if (n != 0 and out.items[n - 1] == d) continue;
        out.items[n] = d;
        n += 1;
    }
    out.shrinkRetainingCapacity(n);
    via.* = if (direct_members == 0 and sources == 1) through else null;
}

/// One declaration's instructions, with a parent map (an error path only).
const Body = struct {
    bir: *const Bir,
    decl: Bir.Decl,
    parents: []u32,
    scratch: Allocator,

    const no_parent = std.math.maxInt(u32);

    fn init(bir: *const Bir, scratch: Allocator, index: u32) Error!Body {
        const d = bir.decls[index];
        const start = d.inst_start.int();
        const end = d.inst_end.int();
        const parents = try scratch.alloc(u32, end - start);
        @memset(parents, no_parent);
        var kids: std.ArrayList(Bir.Inst.Index) = .empty;
        defer kids.deinit(scratch);
        for (start..end) |i| {
            kids.clearRetainingCapacity();
            try Decl.pushChildren(bir, scratch, @enumFromInt(i), &kids);
            for (kids.items) |k| {
                if (k.int() >= start and k.int() < end) parents[k.int() - start] = @intCast(i);
            }
        }
        return .{ .bir = bir, .decl = d, .parents = parents, .scratch = scratch };
    }

    fn deinit(b: *Body, scratch: Allocator) void {
        scratch.free(b.parents);
    }

    fn parent(b: *const Body, inst: Bir.Inst.Index) ?Bir.Inst.Index {
        const start = b.decl.inst_start.int();
        if (inst.int() < start or inst.int() - start >= b.parents.len) return null;
        const p = b.parents[inst.int() - start];
        return if (p == no_parent) null else @enumFromInt(p);
    }

    /// The body of the `let` function `call` (a `call` instruction) calls,
    /// when its callee is a local bound by one.
    fn calledFunction(b: *const Body, call: Bir.Inst.OptionalIndex) ?Bir.Inst.Index {
        const bir = b.bir;
        const c = call.unwrap() orelse return null;
        if (c.int() >= bir.insts.len or bir.instTag(c) != .call) return null;
        const callee: Bir.Inst.Index = @enumFromInt(bir.instData(c).lhs);
        if (bir.instTag(callee) != .local) return null;
        const local = b.decl.locals_start + bir.instData(callee).lhs;
        if (local >= bir.locals.len or bir.locals[local].kind != .let) return null;
        return functionBody(bir, bir.locals[local].inst);
    }

    /// The body of the innermost `let` function around `inst`.
    fn enclosingFunction(b: *const Body, inst: Bir.Inst.Index) ?Bir.Inst.Index {
        var at = inst;
        while (b.parent(at)) |p| : (at = p) {
            if (functionBody(b.bir, p)) |body| return body;
        }
        return null;
    }

    fn functionBody(bir: *const Bir, inst: Bir.Inst.Index) ?Bir.Inst.Index {
        if (bir.instTag(inst) != .let_def) return null;
        const def = bir.extraData(@enumFromInt(bir.instData(inst).lhs), Bir.LetDef);
        if (def.params_start == def.params_end) return null;
        return @enumFromInt(bir.instData(inst).rhs);
    }

    /// Members of `class` referenced under `root` — by value, or by a method
    /// call of a member's name — into `out`, and the locals it names
    /// (absolute indices) into `locals`.
    fn refs(b: *const Body, root: Bir.Inst.Index, class: []const u32, out: *std.ArrayList(u32), locals: *std.ArrayList(u32)) Error!void {
        const bir = b.bir;
        var stack: std.ArrayList(Bir.Inst.Index) = .empty;
        defer stack.deinit(b.scratch);
        try stack.append(b.scratch, root);
        while (stack.pop()) |inst| {
            const data = bir.instData(inst);
            switch (bir.instTag(inst)) {
                .top => if (std.mem.indexOfScalar(u32, class, data.lhs) != null) try out.append(b.scratch, data.lhs),
                .method_call => {
                    const name = bir.symbol(bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall).name);
                    for (class) |d| {
                        if (bir.symbol(bir.decls[d].name) == name) try out.append(b.scratch, d);
                    }
                },
                .local => try locals.append(b.scratch, b.decl.locals_start + data.lhs),
                else => {},
            }
            try Decl.pushChildren(bir, b.scratch, inst, &stack);
        }
    }

    /// The producers of local `local`, transitively through the locals its
    /// source names, each local followed once (`seen`).
    fn follow(b: *const Body, local: u32, class: []const u32, out: *std.ArrayList(u32), seen: *std.AutoHashMapUnmanaged(u32, void)) Error!void {
        var pending: std.ArrayList(u32) = .empty;
        defer pending.deinit(b.scratch);
        try pending.append(b.scratch, local);
        while (pending.pop()) |l| {
            if ((try seen.getOrPut(b.scratch, l)).found_existing) continue;
            const source = b.sourceOf(l) orelse continue;
            try b.refs(source, class, out, &pending);
        }
    }

    /// The expression local `local`'s value comes from: a `let` constant's
    /// body, or the `case` scrutinee or `let` value a pattern destructures.
    /// A parameter's comes from callers, and has none here.
    fn sourceOf(b: *const Body, local: u32) ?Bir.Inst.Index {
        const bir = b.bir;
        if (local >= bir.locals.len) return null;
        const l = bir.locals[local];
        switch (l.kind) {
            .let => {
                if (bir.instTag(l.inst) != .let_def) return null;
                const data = bir.instData(l.inst);
                const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
                if (def.params_start != def.params_end) return null;
                return @enumFromInt(data.rhs);
            },
            .pattern => {
                var at = l.inst;
                while (b.parent(at)) |p| : (at = p) {
                    switch (bir.instTag(p)) {
                        .branch => {
                            const case = b.parent(p) orelse return null;
                            if (bir.instTag(case) != .case) return null;
                            return @enumFromInt(bir.instData(case).lhs);
                        },
                        .let_pattern => return @enumFromInt(bir.instData(p).rhs),
                        .lambda, .let_def => return null,
                        else => {},
                    }
                }
                return null;
            },
            .param, .fresh => return null,
        }
    }
};

// ---------------------------------------------------------------------------
// A cycle through a merged group (§10.6)
// ---------------------------------------------------------------------------

/// A cycle through the merged group `decl` belongs to (§10.6, CK-70): its
/// members in call order, from the one whose name is smallest by text back
/// to it; null when `decl`'s group merged with no other. The edges are read
/// off the members' Bir — value references, and method calls by a member's
/// name — so the answer is a function of the program, not of which member
/// was checked first. Allocated in scratch.
pub fn cycle(gs: *Groups, decl: u32) Error!?[]const Symbol {
    const cx = gs.cx;
    const bir = cx.bir;
    const scratch = cx.scratch;
    if (decl >= gs.group_of.len or gs.group_of[decl] == Groups.none) return null;
    const class = try classOf(gs, decl);
    defer scratch.free(class);
    var merged = false;
    for (class) |d| {
        if (gs.group_of[d] != gs.group_of[class[0]]) merged = true;
    }
    if (!merged) return null;
    // Edges, as indices into `class`: `next[i]` lists `class[i]`'s targets
    // in class (text) order.
    const next = try scratch.alloc(std.ArrayList(u32), class.len);
    defer {
        for (next) |*n| n.deinit(scratch);
        scratch.free(next);
    }
    for (next) |*n| n.* = .empty;
    for (class, next) |d, *n| {
        var targets: std.ArrayList(u32) = .empty;
        defer targets.deinit(scratch);
        var unused: std.ArrayList(u32) = .empty;
        defer unused.deinit(scratch);
        var body: Body = try .init(bir, scratch, d);
        defer body.deinit(scratch);
        if (bir.decls[d].body.unwrap()) |root| try body.refs(root, class, &targets, &unused);
        for (class, 0..) |t, i| {
            if (std.mem.indexOfScalar(u32, targets.items, t) != null) try n.append(scratch, @intCast(i));
        }
    }
    // The shortest cycle through `class[0]`, breadth first in text order.
    const from = try scratch.alloc(u32, class.len);
    defer scratch.free(from);
    @memset(from, Groups.none);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(scratch);
    try queue.append(scratch, 0);
    var head: usize = 0;
    var last: ?u32 = null;
    search: while (head < queue.items.len) : (head += 1) {
        const u = queue.items[head];
        for (next[u].items) |v| {
            if (v == 0) {
                last = u;
                break :search;
            }
            if (from[v] != Groups.none) continue;
            from[v] = u;
            try queue.append(scratch, v);
        }
    }
    var out: std.ArrayList(Symbol) = .empty;
    const end = last orelse {
        // No cycle through it among the edges read: the members, in text
        // order, closed.
        for (class) |d| try out.append(scratch, bir.symbol(bir.decls[d].name));
        try out.append(scratch, bir.symbol(bir.decls[class[0]].name));
        return try out.toOwnedSlice(scratch);
    };
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(scratch);
    var at = end;
    while (at != 0) : (at = from[at]) try path.append(scratch, at);
    try out.append(scratch, bir.symbol(bir.decls[class[0]].name));
    var i = path.items.len;
    while (i > 0) {
        i -= 1;
        try out.append(scratch, bir.symbol(bir.decls[class[path.items[i]]].name));
    }
    try out.append(scratch, bir.symbol(bir.decls[class[0]].name));
    return try out.toOwnedSlice(scratch);
}
