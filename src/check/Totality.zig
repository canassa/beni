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
    const string_compare = stringCompareTarget(in);
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
            if (!try target(in, d, body, &edges)) eligible[d] = false;
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
                    if (!try target(in, d, callee, &edges)) {
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
                    if (!try termTarget(in, d, string_compare, in.dispatch.term(callee), &edges)) eligible[d] = false;
                },
                // Reading an ordinary constant can evaluate an evidence thunk.
                .top => {
                    if (!callableDecl(e, in, data.lhs)) try edges.append(a, data.lhs);
                },
                .ext_value => {
                    if (!importTotal(in, data.lhs, data.rhs)) {
                        // A function reference only creates a value. Its call
                        // was checked above; constant reads must be total.
                        const iface = &in.interfaces[data.lhs];
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

fn importTotal(in: Input, module: u32, value: u32) bool {
    const iface = &in.interfaces[module];
    const scheme = iface.values[value].scheme;
    return scheme != .none and iface.schemes[@backingInt(scheme)].total;
}

fn target(in: Input, owner: u32, callee: Inst, edges: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    const data = in.bir.instData(callee);
    return switch (in.bir.instTag(callee)) {
        .top => blk: {
            // Native execution was recognized before this dependency. A
            // genuine direct self-call already disproves totality.
            if (data.lhs == owner) break :blk false;
            try edges.append(in.scratch, data.lhs);
            break :blk true;
        },
        .ext_value => importTotal(in, data.lhs, data.rhs),
        .ctor, .ext_ctor => true,
        else => false,
    };
}

fn termTarget(in: Input, owner: u32, string_compare: StringCompare, term: Dispatch.Term, edges: *std.ArrayList(u32)) std.mem.Allocator.Error!bool {
    return switch (term) {
        .top => |t| blk: {
            if (t.decl.int() == owner) break :blk false;
            try edges.append(in.scratch, t.decl.int());
            break :blk true;
        },
        .ext => |t| importTotal(in, t.module.int(), @backingInt(t.value)),
        .primitive => |primitive| switch (primitive) {
            .strict_eq, .num_compare, .char_compare => true,
            .string_compare => switch (string_compare) {
                .unknown => false,
                .imported => |total| total,
                .own => |decl| blk: {
                    if (decl == owner) break :blk false;
                    try edges.append(in.scratch, decl);
                    break :blk true;
                },
            },
        },
        // Unknown evidence, record field, derived equality and codec calls
        // have no declaration-level termination proof here.
        else => false,
    };
}

fn callableDecl(e: *Effects, in: Input, decl: u32) bool {
    // P6 already resolved this solved scheme for its calling convention.
    // A positive arity proves a function; zero retains the full shape check.
    if (decl < in.dispatch.decls.len and in.dispatch.decls[decl].value_arity != 0) return true;
    const scheme = in.decl_scheme[decl].unwrap() orelse return false;
    const root, _ = e.store.resolved(scheme);
    return switch (e.store.content(root)) {
        .structure => |shape| shape == .func,
        else => false,
    };
}

const StringCompare = union(enum) { unknown, own: u32, imported: bool };

/// The existing string comparison primitive calls core String.compare.
/// Resolve that actual target once, including its not-yet-published own
/// declaration when checking core String itself.
fn stringCompareTarget(in: Input) StringCompare {
    const module = in.graph.lookup(.core, InternPool.WellKnown.String.symbol()) orelse return .unknown;
    if (module == in.module) {
        for (in.bir.decls, 0..) |decl, i| {
            if (in.bir.symbol(decl.name) == InternPool.WellKnown.compare.symbol()) return .{ .own = @intCast(i) };
        }
        return .unknown;
    }
    const iface = &in.interfaces[module.int()];
    const value = iface.findValue(in.interner, InternPool.WellKnown.compare.symbol()) orelse return .unknown;
    return .{ .imported = importTotal(in, module.int(), @backingInt(value)) };
}
