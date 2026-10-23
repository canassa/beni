//! Declaration totality beside effect inference (§26 / effects §14.9).
//! A closed, acyclic execution graph of pure declarations is total. Unknown
//! calls are not edges that can be silently omitted: they disprove the fact.
//! Foreign pure calls (including Js.pure) use their existing total contracts;
//! forming a function value does not execute the body it will later invoke.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Effects = @import("Effects.zig");
const Dispatch = @import("Dispatch.zig");
const Operator = @import("../Operator.zig");
const children = @import("constrain/Decl.zig").pushChildren;
const Inst = Bir.Inst.Index;

pub const Input = struct {
    scratch: std.mem.Allocator,
    bir: *const Bir,
    graph: *const Graph,
    module: Graph.Index,
    interfaces: []const Interface,
    interner: *const InternPool.Global,
    dispatch: *Dispatch,
    decl_scheme: []const Effects.Var.Optional,
    failed: *const std.DynamicBitSetUnmanaged,
};

pub fn run(e: *Effects, in: Input) std.mem.Allocator.Error!void {
    const a = in.scratch;
    const count = in.bir.decls.len;
    var reads: Reads = .{ .in = in };
    e.total = try e.gpa.alloc(bool, count);
    @memset(e.total, false);
    const starts = try a.alloc(u32, count + 1);
    const eligible = try a.alloc(bool, count);
    @memset(eligible, false);
    var edges: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(Inst) = .empty;
    const seen = try a.alloc(u32, in.bir.insts.len);
    @memset(seen, 0);
    for (in.bir.decls, 0..) |decl, di| {
        const d: u32 = @intCast(di);
        starts[d] = @intCast(edges.items.len);
        if (d < in.failed.bit_length and in.failed.isSet(d)) continue;
        if (decl.kind == .foreign_value) {
            eligible[d] = decl.rung == .pure;
            continue;
        }
        if (decl.kind != .value or decl.body == .none) continue;
        const scheme = in.decl_scheme[d].unwrap() orelse continue;
        const callable = callableDecl(e, in, d);
        const v = if (!callable and e.eval[d] != .none) e.eval[d].unwrap().? else scheme;
        // No solved effect node is unknown, never evidence of purity.
        const node = e.nodeOf(v) orelse continue;
        if (e.levelOf(node) != .pure) continue;
        eligible[d] = true;
        var body = decl.body.unwrap().?;
        // `f = λx → …` declares that function; nested returned lambdas do
        // not execute while the outer declaration is called.
        if (decl.params == 0 and in.bir.instTag(body) == .lambda) body = @fromBackingInt(@intCast(in.bir.instData(body).rhs));
        if (decl.params == 0 and callable and in.bir.instTag(decl.body.unwrap().?) != .lambda) {
            // A callable alias invokes the referenced function, rather than
            // merely evaluating its initializer. Complex callable-producing
            // expressions have no invocation proof in this declaration graph.
            if (!try target(&reads, d, body, &edges)) eligible[d] = false;
        }
        stack.clearRetainingCapacity();
        try stack.append(a, body);
        while (stack.pop()) |at| {
            // A disproven declaration cannot acquire a proof. Its callers
            // already depend on this false bit, so further outgoing edges
            // cannot change the answer, even for a cycle through it.
            if (!eligible[d]) break;
            if (seen[at.int()] == d + 1) continue;
            seen[at.int()] = d + 1;
            const data = in.bir.instData(at);
            switch (in.bir.instTag(at)) {
                .lambda => continue,
                .let_def => {
                    const def = in.bir.extraData(@fromBackingInt(@intCast(data.lhs)), Bir.LetDef);
                    if (def.params_start != def.params_end) continue;
                },
                .call => {
                    const callee: Inst = @fromBackingInt(@intCast(data.lhs));
                    const args = in.bir.extraSlice(in.bir.subRange(@fromBackingInt(@intCast(data.rhs))), Inst);
                    if (Operator.atCall(in.graph, in.interfaces, in.bir, in.module, at, in.dispatch, in.interner)) |op| {
                        if (!op.pureTotal()) eligible[d] = false;
                        try stack.appendSlice(a, args);
                        continue;
                    }
                    if (!try target(&reads, d, callee, &edges)) {
                        eligible[d] = false;
                        continue;
                    }
                    // target records the complete direct callee dependency.
                    // Walk argument formation, without rereading the same
                    // callee as a constant/function reference.
                    try stack.appendSlice(a, args);
                    continue;
                },
                .method_call, .type_dispatch => {
                    const site = in.dispatch.siteOf(at) orelse {
                        eligible[d] = false;
                        continue;
                    };
                    const callee = site.callee.unwrap() orelse {
                        eligible[d] = false;
                        continue;
                    };
                    if (!try termTarget(&reads, d, in.dispatch.term(callee), &edges)) eligible[d] = false;
                },
                // Reading an ordinary constant can evaluate an evidence thunk.
                .top => {
                    if (!callableDecl(e, in, data.lhs)) try edges.append(a, data.lhs);
                },
                .ext_value => {
                    if (!try importTotal(&reads, data.lhs, data.rhs)) {
                        // A function reference only creates a value. Its call
                        // was checked above; constant reads must be total.
                        const iface = try reads.iface(data.lhs);
                        const index = iface.values[data.rhs].scheme;
                        if (index == .none) {
                            eligible[d] = false;
                            continue;
                        }
                        const s = iface.schemes[@backingInt(index)];
                        if (iface.terms.items(.tag)[s.body.int()] != .func) eligible[d] = false;
                    }
                },
                else => {},
            }
            try children(in.bir, a, at, &stack);
        }
    }
    starts[count] = @intCast(edges.items.len);
    // The least fixed point of total(d) = eligible(d) AND all total(callee).
    // Only eligible sinks seed a proof; cycles, their callers and unknown
    // callees never drain. Each reverse edge settles once, duplicates too.
    const none = std.math.maxInt(u32);
    const head = try a.alloc(u32, count);
    const next = try a.alloc(u32, edges.items.len);
    const caller = try a.alloc(u32, edges.items.len);
    const remaining = try a.alloc(u32, count);
    const queue = try a.alloc(u32, count);
    @memset(head, none);
    var queued: usize = 0;
    for (0..count) |d| {
        remaining[d] = starts[d + 1] - starts[d];
        if (eligible[d] and remaining[d] == 0) {
            e.total[d] = true;
            queue[queued] = @intCast(d);
            queued += 1;
        }
        for (starts[d]..starts[d + 1]) |edge| {
            const target_decl = edges.items[edge];
            next[edge] = head[target_decl];
            caller[edge] = @intCast(d);
            head[target_decl] = @intCast(edge);
        }
    }
    var cursor: usize = 0;
    while (cursor < queued) : (cursor += 1) {
        var edge = head[queue[cursor]];
        while (edge != none) : (edge = next[edge]) {
            const d = caller[edge];
            if (!eligible[d]) continue;
            std.debug.assert(remaining[d] != 0);
            remaining[d] -= 1;
            if (remaining[d] != 0) continue;
            e.total[d] = true;
            queue[queued] = d;
            queued += 1;
        }
    }
    // EffectPlan can omit its all-empty table. Totality is present even in
    // that case, including private declarations that have no interface row.
    const answers = try e.gpa.alloc(Dispatch.EffectDecl, count);
    for (answers, 0..) |*answer, i| {
        answer.* = in.dispatch.effectDecl(@intCast(i));
        answer.total = e.total[i];
    }
    e.gpa.free(in.dispatch.effect_decls);
    in.dispatch.effect_decls = answers;
}

/// What this check may read of other modules' interfaces. A module starts
/// only once every dependency has finished (`Graph.zig`'s header), so the
/// interfaces of its transitive dependencies are final; any other module's
/// may be being published by another thread at this moment. Reading one
/// would be a data race, and its answer would depend on the schedule
/// (`fast-compiler.md` §10). Every read goes through `iface`.
const Reads = struct {
    in: Input,
    /// The transitive dependencies of `in.module`, computed on first use.
    deps: ?std.DynamicBitSetUnmanaged = null,
    /// `String.compare`, resolved on the first comparison primitive.
    string_compare: ?StringCompare = null,

    fn finished(r: *Reads, module: Graph.Index) std.mem.Allocator.Error!bool {
        if (r.deps == null) {
            const a = r.in.scratch;
            var set = try std.DynamicBitSetUnmanaged.initEmpty(a, r.in.graph.count());
            var stack: std.ArrayList(Graph.Index) = .empty;
            try stack.appendSlice(a, r.in.graph.dependencies(r.in.module));
            while (stack.pop()) |m| {
                if (set.isSet(m.int())) continue;
                set.set(m.int());
                try stack.appendSlice(a, r.in.graph.dependencies(m));
            }
            r.deps = set;
        }
        return r.deps.?.isSet(module.int());
    }

    /// Another module's interface, which must be a finished dependency's.
    fn iface(r: *Reads, module: u32) std.mem.Allocator.Error!*const Interface {
        if (std.debug.runtime_safety and !try r.finished(@fromBackingInt(module))) {
            std.debug.panic("totality read the interface of module {d}, which module {d} does not depend on", .{ module, r.in.module.int() });
        }
        return &r.in.interfaces[module];
    }
};

fn importTotal(r: *Reads, module: u32, value: u32) std.mem.Allocator.Error!bool {
    const iface = try r.iface(module);
    const scheme = iface.values[value].scheme;
    return scheme != .none and iface.schemes[@backingInt(scheme)].total;
}

fn target(r: *Reads, owner: u32, callee: Inst, edges: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    const in = r.in;
    const data = in.bir.instData(callee);
    return switch (in.bir.instTag(callee)) {
        .top => blk: {
            // Native execution was recognized before this dependency. A
            // genuine direct self-call already disproves totality.
            if (data.lhs == owner) break :blk false;
            try edges.append(in.scratch, data.lhs);
            break :blk true;
        },
        .ext_value => try importTotal(r, data.lhs, data.rhs),
        .ctor, .ext_ctor => true,
        else => false,
    };
}

fn termTarget(r: *Reads, owner: u32, term: Dispatch.Term, edges: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    return switch (term) {
        .top => |t| blk: {
            if (t.decl.int() == owner) break :blk false;
            try edges.append(r.in.scratch, t.decl.int());
            break :blk true;
        },
        .ext => |t| try importTotal(r, t.module.int(), @backingInt(t.value)),
        .primitive => |primitive| switch (primitive) {
            .strict_eq, .num_compare, .char_compare => true,
            // `compare$key` is `String.compare` on a string key and native
            // order otherwise (`Lower.compareKeyDecl`), so it is total exactly
            // when that declaration is.
            .string_compare, .key_compare => switch (try stringCompare(r)) {
                .unknown => false,
                .imported => |total| total,
                .own => |decl| blk: {
                    if (decl == owner) break :blk false;
                    try edges.append(r.in.scratch, decl);
                    break :blk true;
                },
            },
        },
        // Unknown evidence, record field, derived equality and codec calls
        // have no declaration-level termination proof here.
        else => false,
    };
}

/// Whether `decl`'s solved scheme is a function: the one source of that
/// fact here, read from the store P4 solved.
fn callableDecl(e: *Effects, in: Input, decl: u32) bool {
    const scheme = in.decl_scheme[decl].unwrap() orelse return false;
    const root, _ = e.store.resolved(scheme);
    return switch (e.store.content(root)) {
        .structure => |shape| shape == .func,
        else => false,
    };
}

const StringCompare = union(enum) { unknown, own: u32, imported: bool };

/// The existing string comparison primitive calls core String.compare.
/// Resolve that actual target on first use, including its not-yet-published
/// own declaration when checking core String itself. A module that does not
/// depend on `String` cannot read its interface (`Reads`): a `string_compare`
/// there is unproven. That happens only for `key_compare` over a key type
/// variable — a module that sees the `String` type depends on its module
/// (`Graph.mintedModules`) — and keeps the answer independent of the order
/// modules finish in.
fn stringCompare(r: *Reads) std.mem.Allocator.Error!StringCompare {
    if (r.string_compare) |s| return s;
    const s = try stringCompareTarget(r);
    r.string_compare = s;
    return s;
}

fn stringCompareTarget(r: *Reads) std.mem.Allocator.Error!StringCompare {
    const in = r.in;
    const module = in.graph.lookup(.core, InternPool.WellKnown.String.symbol()) orelse return .unknown;
    if (module == in.module) {
        for (in.bir.decls, 0..) |decl, i| {
            if (in.bir.symbol(decl.name) == InternPool.WellKnown.compare.symbol()) return .{ .own = @intCast(i) };
        }
        return .unknown;
    }
    if (!try r.finished(module)) return .unknown;
    const iface = try r.iface(module.int());
    const value = iface.findValue(in.interner, InternPool.WellKnown.compare.symbol()) orelse return .unknown;
    return .{ .imported = try importTotal(r, module.int(), @backingInt(value)) };
}
