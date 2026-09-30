//! The `sync` check (transparent-effects-proposal.md §15.4, checker-v2.md
//! §27): after `Effects.run`, every demand whose class reached `suspends` is
//! an error, one per class, reported in region order.
//!
//! **The message names the boundary, then the chain.** The chain is read off
//! this module's own solved graph, backwards from the class that must not
//! suspend: along the call edges that carry `suspends` into it, into an own
//! declaration's body where a copy of its summary suspends, to the first
//! value that suspends by itself — an imported value, whose module's record
//! says so, or an own `foreign suspends`. One hop per module (the owner's
//! decision 7a): nothing here reads another module's body, and nothing is
//! kept for it. The chain names declarations, not lines — the checker holds
//! the module's instructions, not its line table.
//!
//! Only the error path does any of this: a module whose demands all hold
//! pays one pass over its demands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const TypeStore = @import("TypeStore.zig");
const Context = @import("Context.zig");
const Report = @import("Report.zig");
const Effects = @import("Effects.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Allocator.Error;
const none = Effects.none;

/// What the check reads of the module's check.
pub const Input = struct {
    cx: *const Context,
    report: *Report,
    decl_scheme: []const Var.Optional,
};

pub fn check(e: *Effects, in: Input) Error!void {
    const s = &e.solved;
    if (s.sources.items.len == 0) return;
    const scratch = in.cx.scratch;
    // One error per class: the first demand met on it.
    const seen = try scratch.alloc(bool, s.nodes());
    defer scratch.free(seen);
    @memset(seen, false);
    var picked: std.ArrayList(Picked) = .empty;
    defer picked.deinit(scratch);
    for (s.sources.items, 0..) |src, i| {
        const root = s.find(src.node);
        if (s.level.items[root] != .suspends or seen[root]) continue;
        seen[root] = true;
        try picked.append(scratch, .{ .source = @intCast(i), .region = none, .token = null });
    }
    if (picked.items.len == 0) return;

    var sync: Sync = .{ .e = e, .in = in, .scratch = scratch };
    try sync.build();
    defer sync.deinit();
    sync.roots = try scratch.alloc(bool, s.nodes());
    @memset(sync.roots, false);
    for (picked.items) |p| {
        const src = s.sources.items[p.source];
        if (src.demand.kind == .main or src.demand.kind == .value or src.demand.kind == .method) sync.roots[s.find(src.node)] = true;
    }
    for (picked.items) |*p| {
        const src = &s.sources.items[p.source];
        try sync.locate(src);
        p.region, p.token = sync.regionOf(src.*);
    }
    std.mem.sort(Picked, picked.items, {}, Picked.before);
    // Attributed to no declaration: a refusal here sets no failure bit P7
    // or P8 reads (checker-v2.md §27).
    in.report.at(null);
    for (picked.items) |p| {
        const src = s.sources.items[p.source];
        const text = (try sync.message(src)) orelse continue;
        defer in.cx.gpa.free(text);
        const code: diagnostic.Code = switch (src.demand.kind) {
            .main, .value, .method => .must_not_suspend,
            else => .sync_boundary,
        };
        try in.report.emitText(code, @enumFromInt(p.region), p.token, text);
    }
}

const Picked = struct {
    source: u32,
    region: u32,
    token: ?u32,

    fn before(_: void, a: Picked, b: Picked) bool {
        if (a.region != b.region) return a.region < b.region;
        return a.source < b.source;
    }
};

const Sync = struct {
    e: *Effects,
    in: Input,
    scratch: Allocator,
    /// Per node: the edges into it, as `(from, edge)` lists.
    rev_head: []u32 = &.{},
    rev_next: std.ArrayList(u32) = .empty,
    rev_from: std.ArrayList(u32) = .empty,
    rev_edge: std.ArrayList(u32) = .empty,
    /// Per node: the classes of own declarations' summaries it is a copy
    /// of, a list through `jump_next` (`none` ends it), with each
    /// class's declaration.
    jump: []u32 = &.{},
    jump_next: std.ArrayList(u32) = .empty,
    jump_class: std.ArrayList(u32) = .empty,
    jump_decl: std.ArrayList(u32) = .empty,
    /// Per node: the imported use that suspends by itself (`terminals`
    /// index + 1), or the own `foreign suspends` whose class it is (+ 1).
    imported: []u32 = &.{},
    foreign: []u32 = &.{},
    /// Per node: a refused `main` or `eq`/`compare` is on it, and whether
    /// the last chain ran through one.
    roots: []bool = &.{},
    through_root: bool = false,

    fn deinit(y: *Sync) void {
        const a = y.scratch;
        a.free(y.rev_head);
        y.rev_next.deinit(a);
        y.rev_from.deinit(a);
        y.rev_edge.deinit(a);
        a.free(y.jump);
        y.jump_next.deinit(a);
        y.jump_class.deinit(a);
        y.jump_decl.deinit(a);
        a.free(y.imported);
        a.free(y.foreign);
        a.free(y.roots);
    }

    fn column(y: *Sync, fill: u32) Error![]u32 {
        const c = try y.scratch.alloc(u32, y.e.solved.nodes());
        @memset(c, fill);
        return c;
    }

    /// The reverse graph, the copies' classes and the chain's ends: built
    /// once, on the error path.
    fn build(y: *Sync) Error!void {
        const e = y.e;
        const s = &e.solved;
        const a = y.scratch;
        y.rev_head = try y.column(none);
        y.jump = try y.column(none);
        y.imported = try y.column(0);
        y.foreign = try y.column(0);
        for (0..s.nodes()) |x| {
            var at = s.head.items[x];
            while (at != none) : (at = s.next.items[at]) {
                const to = s.find(s.to.items[at]);
                try y.rev_from.append(a, @intCast(x));
                try y.rev_edge.append(a, at);
                try y.rev_next.append(a, y.rev_head[to]);
                y.rev_head[to] = @intCast(y.rev_from.items.len - 1);
            }
        }
        for (e.records.items) |r| {
            const target = declOf(e.scheme_decl, r.scheme) orelse continue;
            for (e.pairs.items[r.start..][0..r.len]) |p| {
                const copy = e.nodeOf(p.b) orelse continue;
                const class = e.nodeOf(p.a) orelse continue;
                if (s.classIndex(target, class) == null or copy == class) continue;
                // One copy may be several declarations' at once — an
                // argument unified with the parameter it is passed to.
                try y.jump_class.append(a, class);
                try y.jump_decl.append(a, target);
                try y.jump_next.append(a, y.jump[copy]);
                y.jump[copy] = @intCast(y.jump_class.items.len - 1);
            }
        }
        for (e.terminals.items, 0..) |t, i| {
            const nd = e.nodeOf(t.v) orelse continue;
            if (y.imported[nd] == 0) y.imported[nd] = @intCast(i + 1);
        }
        for (y.in.cx.bir.decls, 0..) |d, i| {
            if (d.kind != .foreign_value or d.rung != .suspends) continue;
            for (s.classesOf(@intCast(i))) |c| {
                if (c.rung == .suspends) y.foreign[s.find(c.node)] = @intCast(i + 1);
            }
        }
    }

    // ---- Where the error points --------------------------------------

    /// A demand a use made from an own declaration's summary says where its
    /// class sits in the declaration's scheme only now: its first path.
    fn locate(y: *Sync, src: *Effects.Source) Error!void {
        if (src.target == none) return;
        const e = y.e;
        const store = e.store;
        if (src.target >= y.in.decl_scheme.len) return;
        const scheme = y.in.decl_scheme[src.target].unwrap() orelse return;
        const classes = e.solved.classesOf(src.target);
        if (src.class >= classes.len) return;
        const want = classes[src.class].node;
        const Frame = struct { v: Var, depth: u32, param: u32, field: u32, method: u32 };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(y.scratch);
        try stack.append(y.scratch, .{ .v = scheme, .depth = 0, .param = none, .field = none, .method = none });
        const mark = store.nextMark();
        while (stack.pop()) |f| {
            const r = store.find(f.v);
            if (store.mark(r) == mark) continue;
            store.setMark(r, mark);
            switch (store.content(r)) {
                .flex, .rigid => |flags| {
                    const set = Walk.constraints(flags);
                    for (0..set.count(store)) |i| {
                        const c = set.at(store, @intCast(i));
                        try stack.append(y.scratch, .{ .v = c.fn_var, .depth = 2, .param = none, .field = none, .method = @intFromEnum(c.name) });
                    }
                    continue;
                },
                else => {},
            }
            if (e.carries(r)) if (e.nodeOf(r)) |nd| if (nd == want) {
                src.demand.param = f.param;
                src.demand.field = f.field;
                src.demand.method = f.method;
                return;
            };
            var k: u32 = 0;
            while (Walk.stepped(store, r, k)) |c| : (k += 1) {
                var next: Frame = .{ .v = c.v, .depth = f.depth + 1, .param = f.param, .field = f.field, .method = f.method };
                switch (c.kind) {
                    // An alias's expansion is the same position.
                    .expansion => next.depth = f.depth,
                    .param => if (f.depth == 0) {
                        next.param = c.index;
                    },
                    .field => if (f.depth == 1 and f.param != none) {
                        next.field = c.index;
                    },
                    else => {},
                }
                try stack.append(y.scratch, next);
            }
        }
    }

    /// The region and token a demand's error points at (§15.4's table).
    fn regionOf(y: *const Sync, src: Effects.Source) struct { u32, ?u32 } {
        const bir = y.in.cx.bir;
        const d = src.demand;
        switch (d.kind) {
            .main, .value, .method => {
                const decl = bir.decls[d.decl];
                return .{ @intFromEnum(decl.inst_start), decl.name_token };
            },
            .handler, .row, .key, .signature => return .{ d.site, null },
            .argument => {},
        }
        if (d.site >= bir.insts.len or d.param == none) return .{ d.site, null };
        const arg = y.argument(d.site, d.param) orelse return .{ d.site, null };
        if (d.field != none and bir.instTag(arg) == .record) {
            for (bir.extraSlice(Bir.inlineRange(bir.instData(arg)), Bir.Field)) |f| {
                if (@intFromEnum(bir.symbol(f.name)) == d.field) return .{ @intFromEnum(f.value), null };
            }
        }
        return .{ @intFromEnum(arg), null };
    }

    /// The argument at parameter `param` of the call whose callee is the
    /// use `site`: a `call` naming it, or the method call it is.
    fn argument(y: *const Sync, site: u32, param: u32) ?Bir.Inst.Index {
        const bir = y.in.cx.bir;
        const at: Bir.Inst.Index = @enumFromInt(site);
        if (bir.instTag(at) == .method_call) {
            const data = bir.instData(at);
            if (param == 0) return @enumFromInt(data.lhs);
            const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
            const args = bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index);
            return if (param - 1 < args.len) args[param - 1] else null;
        }
        const decl = declAt(bir, site) orelse return null;
        var i = @intFromEnum(decl.inst_start);
        while (i < @intFromEnum(decl.inst_end)) : (i += 1) {
            const inst: Bir.Inst.Index = @enumFromInt(i);
            if (bir.instTag(inst) != .call or bir.instData(inst).lhs != site) continue;
            const args = bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(inst).rhs)), Bir.Inst.Index);
            return if (param < args.len) args[param] else null;
        }
        return null;
    }

    // ---- The chain -----------------------------------------------------

    const Step = union(enum) {
        /// An edge a call wrote: `Effects.sites` index.
        call: u32,
        /// An edge no call wrote: a function handed along.
        handed,
        /// Into an own declaration's body, whose summary the copy read.
        into: u32,
    };

    const End = union(enum) { none, imported: u32, foreign: u32 };

    /// The shortest path of `suspends` from where it starts to `start`,
    /// as the steps met walking out from `start`.
    fn chain(y: *Sync, start: u32, steps: *std.ArrayList(Step)) Error!End {
        const s = &y.e.solved;
        const a = y.scratch;
        const parent = try y.column(none);
        defer a.free(parent);
        const via = try a.alloc(Step, s.nodes());
        defer a.free(via);
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(a);
        try queue.append(a, start);
        parent[start] = start;
        var head: usize = 0;
        const found: u32, const end: End = while (head < queue.items.len) : (head += 1) {
            const x = queue.items[head];
            if (y.imported[x] != 0) break .{ x, .{ .imported = y.imported[x] - 1 } };
            if (y.foreign[x] != 0) break .{ x, .{ .foreign = y.foreign[x] - 1 } };
            var j = y.jump[x];
            while (j != none) : (j = y.jump_next.items[j]) {
                const t = s.find(y.jump_class.items[j]);
                if (parent[t] == none and s.level.items[t] == .suspends) {
                    parent[t] = x;
                    via[t] = .{ .into = y.jump_decl.items[j] };
                    try queue.append(a, t);
                }
            }
            var at = y.rev_head[x];
            while (at != none) : (at = y.rev_next.items[at]) {
                const from = s.find(y.rev_from.items[at]);
                if (parent[from] != none or s.level.items[from] != .suspends) continue;
                parent[from] = x;
                const origin = s.origin.items[y.rev_edge.items[at]];
                via[from] = if (origin == none or y.e.sites.items[origin].call == none) .handed else .{ .call = origin };
                try queue.append(a, from);
            }
        } else return .none;
        // Walk back from the end to `start`, then read it forwards.
        var at = found;
        const mark = steps.items.len;
        y.through_root = false;
        while (at != start) : (at = parent[at]) {
            if (y.roots[at]) y.through_root = true;
            try steps.append(a, via[at]);
        }
        std.mem.reverse(Step, steps.items[mark..]);
        return end;
    }

    // ---- The message -----------------------------------------------------

    /// The message, or null when the chain runs through a declaration that
    /// is refused itself (`main`, a type's `eq` or `compare`): that error
    /// says it, and this one would say it again.
    fn message(y: *Sync, src: Effects.Source) Error!?[]u8 {
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(y.scratch);
        const end = try y.chain(y.e.solved.find(src.node), &steps);
        const root = src.demand.kind == .main or src.demand.kind == .value or src.demand.kind == .method;
        if (!root and y.through_root) return null;
        const gpa = y.in.cx.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        y.lead(w, src) catch return error.OutOfMemory;
        w.writeAll("\n\nBut it may suspend: ") catch return error.OutOfMemory;
        y.explain(w, src, steps.items, end) catch return error.OutOfMemory;
        w.writeAll("\n\n") catch return error.OutOfMemory;
        y.hint(w, src) catch return error.OutOfMemory;
        return try out.toOwnedSlice();
    }

    /// What must not suspend, and why.
    fn lead(y: *Sync, w: *std.Io.Writer, src: Effects.Source) std.Io.Writer.Error!void {
        const d = src.demand;
        const cx = y.in.cx;
        switch (d.kind) {
            .main => return w.writeAll(
                "`main` must not suspend: it is evaluated once, when the program starts, where nothing can wait for it.",
            ),
            .value => {
                const decl = cx.bir.decls[d.decl];
                return w.print(
                    "`{s}` must not suspend: it is a value, evaluated once, when its module is loaded, where nothing can wait for it.",
                    .{cx.interner.slice(cx.bir.symbol(decl.name))},
                );
            },
            .method => {
                const decl = cx.bir.decls[d.decl];
                const name = cx.interner.slice(cx.bir.symbol(decl.name));
                const type_name = if (d.field != none) cx.interner.slice(@enumFromInt(d.field)) else "its type";
                const ops = if (std.mem.eql(u8, name, "eq")) "`==` and `/=`" else "`<`, `<=`, `>`, `>=`, `min` and `max`";
                return w.print(
                    "`{s}` must not suspend: it is what {s} call on `{s}`, and a comparison never suspends. `List` compares its elements from JavaScript, where nothing can wait.",
                    .{ name, ops, type_name },
                );
            },
            .handler => return w.writeAll("This handler must not suspend: the page calls it synchronously, while the event is being dispatched."),
            .row => return w.writeAll("This row function must not suspend: the page calls it synchronously, while it renders."),
            .key => return w.writeAll("This key function must not suspend: the page calls it synchronously, while it renders."),
            .signature => {
                const decl = cx.bir.decls[d.decl];
                return w.print(
                    "This function must not suspend: `{s}`'s signature marks it `sync`, so every caller is held to it.",
                    .{cx.interner.slice(cx.bir.symbol(decl.name))},
                );
            },
            .argument => {},
        }
        var callee: std.Io.Writer.Allocating = .init(y.scratch);
        defer callee.deinit();
        try y.referenceName(&callee.writer, d.site);
        const name = callee.written();
        if (d.method != none) {
            return w.print("The `{s}` this call hands `{s}` must not suspend: `{s}` calls it synchronously.", .{ cx.interner.slice(@enumFromInt(d.method)), name, name });
        }
        if (d.field != none) {
            try w.print("The `{s}` function here must not suspend: ", .{cx.interner.slice(@enumFromInt(d.field))});
        } else if (d.holder) {
            try w.writeAll("This value holds a function that must not suspend: ");
        } else {
            try w.writeAll("This function must not suspend: ");
        }
        switch (y.calleeKind(d.site)) {
            .platform => try w.print("`{s}` hands it to the platform, which calls it synchronously.", .{name}),
            .operator => try w.print("`{s}` calls it, through the type's own comparison, and a comparison never suspends.", .{name}),
            .beni => try w.print("`{s}` hands it on to a function that calls it synchronously.", .{name}),
        }
    }

    /// The chain (§15.4), in one sentence.
    fn explain(y: *Sync, w: *std.Io.Writer, src: Effects.Source, steps: []const Step, end: End) std.Io.Writer.Error!void {
        const e = y.e;
        const cx = y.in.cx;
        var first = true;
        var handed = false;
        // The reference the last call named, to say "which suspends" of it.
        var last_ref: u32 = none;
        for (steps) |step| switch (step) {
            .handed => if (!first) {
                handed = true;
            },
            .into => handed = false,
            .call => |origin| {
                const site = e.sites.items[origin];
                if (first) {
                    try y.subject(w, site, src, true);
                    try w.writeAll(" calls `");
                } else if (handed) {
                    try w.writeAll(" with a function that calls `");
                } else {
                    try w.writeAll(", and ");
                    try y.subject(w, site, src, false);
                    try w.writeAll(" calls `");
                }
                try y.calleeName(w, site.call);
                try w.writeByte('`');
                last_ref = y.calleeReference(site.call);
                first = false;
                handed = false;
            },
        };
        const end_ref: u32, const end_decl: u32 = switch (end) {
            .none => {
                if (first) return w.writeAll("something it calls may suspend.");
                return w.writeAll(", which may suspend.");
            },
            .imported => |i| .{ e.terminals.items[i].site, none },
            .foreign => |d| .{ none, d },
        };
        const same = if (end_decl != none)
            last_ref != none and cx.bir.instTag(@enumFromInt(last_ref)) == .top and cx.bir.instData(@enumFromInt(last_ref)).lhs == end_decl
        else
            last_ref == end_ref;
        if (first) {
            try w.writeByte('`');
            try y.endName(w, end_ref, end_decl);
            return w.writeAll("` suspends.");
        }
        if (same) return w.writeAll(", which suspends.");
        try w.writeAll(" with `");
        try y.endName(w, end_ref, end_decl);
        try w.writeAll("`, which suspends.");
    }

    fn endName(y: *Sync, w: *std.Io.Writer, ref: u32, decl: u32) std.Io.Writer.Error!void {
        const cx = y.in.cx;
        if (decl != none) return w.writeAll(cx.interner.slice(cx.bir.symbol(cx.bir.decls[decl].name)));
        return y.referenceName(w, ref);
    }

    /// Who makes a call: the declaration, a `let` function, a lambda — or,
    /// first in the chain, "it" for the function the error points at.
    fn subject(y: *Sync, w: *std.Io.Writer, site: Effects.Site, src: Effects.Source, first: bool) std.Io.Writer.Error!void {
        const bir = y.in.cx.bir;
        const cx = y.in.cx;
        if (site.ambient != none and site.ambient < bir.insts.len) {
            const at: Bir.Inst.Index = @enumFromInt(site.ambient);
            if (bir.instTag(at) == .let_def) {
                const def = bir.extraData(@enumFromInt(bir.instData(at).lhs), Bir.LetDef);
                if (declAt(bir, site.ambient)) |d| {
                    const local = d.locals_start + def.local;
                    if (local < bir.locals.len and bir.locals[local].name != .none) {
                        return w.print("`{s}`", .{cx.interner.slice(bir.symbol(bir.locals[local].name))});
                    }
                }
            } else if (first and src.demand.kind != .main and src.demand.kind != .value and src.demand.kind != .method) {
                // The first call made inside the function the error points at.
                return w.writeAll(if (src.demand.holder) "the function it holds" else "it");
            }
            try w.writeAll("a function in `");
            if (declAt(bir, site.ambient)) |d| try w.writeAll(cx.interner.slice(bir.symbol(d.name)));
            return w.writeByte('`');
        }
        const d = declAt(bir, site.call) orelse return w.writeAll("it");
        try w.print("`{s}`", .{cx.interner.slice(bir.symbol(d.name))});
    }

    /// The reference a call names: its callee, or the method call itself.
    fn calleeReference(y: *const Sync, call: u32) u32 {
        const bir = y.in.cx.bir;
        if (call >= bir.insts.len) return none;
        const at: Bir.Inst.Index = @enumFromInt(call);
        return if (bir.instTag(at) == .call) bir.instData(at).lhs else call;
    }

    fn calleeName(y: *Sync, w: *std.Io.Writer, call: u32) std.Io.Writer.Error!void {
        const ref = y.calleeReference(call);
        if (ref == none) return w.writeAll("a function");
        return y.referenceName(w, ref);
    }

    /// A reference as the author could write it: an own name bare, an
    /// imported one qualified by its module, a method call by its operator
    /// or method name.
    fn referenceName(y: *Sync, w: *std.Io.Writer, ref: u32) std.Io.Writer.Error!void {
        const cx = y.in.cx;
        const bir = cx.bir;
        if (ref == none or ref >= bir.insts.len) return w.writeAll("a function");
        const at: Bir.Inst.Index = @enumFromInt(ref);
        const data = bir.instData(at);
        switch (bir.instTag(at)) {
            .top => if (data.lhs < bir.decls.len) return w.writeAll(cx.interner.slice(bir.symbol(bir.decls[data.lhs].name))),
            .ext_value => if (data.lhs < cx.interfaces.len) {
                const module: Graph.Index = @enumFromInt(data.lhs);
                const iface = cx.iface(module);
                if (data.rhs < iface.values.len) return w.print("{s}.{s}", .{
                    cx.interner.slice(cx.graph.moduleName(module)),
                    cx.interner.slice(iface.valueName(@enumFromInt(data.rhs))),
                });
            },
            .local => if (declAt(bir, ref)) |d| {
                const local = d.locals_start + data.lhs;
                if (local < bir.locals.len and bir.locals[local].name != .none) return w.writeAll(cx.interner.slice(bir.symbol(bir.locals[local].name)));
            },
            .method_call => {
                const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
                if (m.origin.spelling()) |op| return w.writeAll(op);
                return w.writeAll(cx.interner.slice(bir.symbol(m.name)));
            },
            else => {},
        }
        return w.writeAll("a function");
    }

    const CalleeKind = enum { platform, operator, beni };

    fn calleeKind(y: *const Sync, site: u32) CalleeKind {
        const cx = y.in.cx;
        const bir = cx.bir;
        if (site >= bir.insts.len) return .beni;
        const at: Bir.Inst.Index = @enumFromInt(site);
        const data = bir.instData(at);
        return switch (bir.instTag(at)) {
            .top => if (data.lhs < bir.decls.len and (bir.decls[data.lhs].kind == .foreign_value or bir.decls[data.lhs].kind == .vocab_markup)) .platform else .beni,
            .ext_value => blk: {
                if (data.lhs >= cx.interfaces.len) break :blk .beni;
                const iface = cx.iface(@enumFromInt(data.lhs));
                if (data.rhs >= iface.values.len) break :blk .beni;
                const value = iface.values[data.rhs];
                break :blk if (value.is_foreign or value.is_markup_primitive) .platform else .beni;
            },
            .method_call => if (bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall).origin.spelling() != null) .operator else .beni,
            else => .beni,
        };
    }

    fn hint(y: *Sync, w: *std.Io.Writer, src: Effects.Source) std.Io.Writer.Error!void {
        _ = y;
        switch (src.demand.kind) {
            .main => try w.writeAll(
                "Hint: `main` only describes the program. A value that may suspend can only be computed by a function the platform runs, never while `main` is evaluated.",
            ),
            .value => try w.writeAll(
                "Hint: make it a function — `\\() -> …` or a parameter — and call it where waiting is possible, from a function the platform runs.",
            ),
            .method => try w.writeAll(
                "Hint: compare what the values hold, and do the work that suspends before comparing them.",
            ),
            else => try w.writeAll(
                "Hint: a function called synchronously cannot wait for anything. Do the work that suspends before handing this function over, and pass it what that work produced.",
            ),
        }
        try w.writeByte('\n');
    }
};

/// The own declaration whose scheme's root is `scheme`.
fn declOf(pairs: []const [2]u32, scheme: Var) ?u32 {
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = pairs[mid][0];
        if (at < scheme.int()) lo = mid + 1 else if (at > scheme.int()) hi = mid else return pairs[mid][1];
    }
    return null;
}

/// The declaration whose instructions hold `inst`.
fn declAt(bir: *const Bir, inst: u32) ?Bir.Decl {
    for (bir.decls) |d| {
        if (inst >= @intFromEnum(d.inst_start) and inst < @intFromEnum(d.inst_end)) return d;
    }
    return null;
}
