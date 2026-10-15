//! Bare-dot resolution without eagerly constructing method/effect objects.
//! Flexible receivers still wait for the same owner-rank boundary default.
//! A late arrow wraps existing variables: ordinary rank folding lowers the
//! fresh wrapper to those dependencies before generalisation.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Tree = @import("constrain/Tree.zig");
const Solve = @import("Solve.zig");
const TypeStore = @import("TypeStore.zig");
const InternPool = @import("../InternPool.zig");
const Effects = @import("Effects.zig");
const Evidence = @import("Evidence.zig");
const Resolve = @import("Resolve.zig");
const Instances = @import("Instances.zig");
const Obligations = @import("Obligations.zig");
const Decide = @import("Decide.zig");
const Recursion = @import("Recursion.zig");
const Walk = @import("Walk.zig");
const Error = Solve.Error;
const Var = TypeStore.Var;

pub const Pending = struct { name: InternPool.Symbol, effect_edge: u32, decl: u32 };

pub fn begin(s: *Solve, node: Tree.Node) Error!void {
    const d = s.tree.extraData(node.a, Tree.FieldDot);
    const st = s.store();
    const root, const content = st.resolved(d.receiver);
    if (s.recursive_frames == 0) {
        if (isRecord(content) and try cheap(s, root, d.name)) {
            s.obligations.seq += 2;
            s.resolver.steps += 1;
            return Instances.fieldRead(s, d.receiver, d.name, d.result, node.region);
        }
        if (content == .flex) {
            const index: u32 = @intCast(s.field_dots.items.len);
            try s.field_dots.append(s.cx.gpa, .{
                .name = d.name,
                .effect_edge = d.effect_edge,
                .decl = s.report.current orelse Evidence.Wanted.no_decl,
            });
            // Reserve the original wanted's slot; the row takes the next.
            s.obligations.seq += 1;
            const row = try s.obligations.create(s.cx.gpa, .field_dot, node.region, &.{ d.receiver, d.result }, index, null);
            return Decide.begin(s, row);
        }
    }
    const method_type = try arrow(s, d.receiver, d.result, d.effect_edge);
    return Resolve.methodInfo(s, .{
        .name = d.name,
        .receiver = d.receiver,
        .method_type = method_type,
        .kind = @backingInt(Evidence.Kind.dot_call),
        .var_name = @backingInt(Tree.Symbol.Optional.none),
    }, node.region);
}

pub fn decide(s: *Solve, id: Obligations.Id, default: bool) Error!void {
    const row = s.obligations.row(id);
    const p = s.field_dots.items[row.index];
    const st = s.store();
    const root, const content = st.resolved(row.vars[0]);
    const saved = s.report.current;
    s.report.at(if (p.decl == Evidence.Wanted.no_decl) saved else p.decl);
    defer s.report.at(saved);
    if (content == .flex) {
        // Numeric aliases may be decided before defaulting. Preserve the
        // legacy bridge before retrying a still-flexible receiver.
        if (!(content.flex.kind == .number and Resolve.isWellKnownName(p.name))) {
            if (!default) return Decide.reopen(s, id);
            if (s.recursive_frames == 0)
                return Instances.fieldRead(s, row.vars[0], p.name, row.vars[1], row.region);
        }
    } else if (isRecord(content) and s.recursive_frames == 0 and try cheap(s, root, p.name)) {
        s.resolver.steps += 1;
        return Instances.fieldRead(s, row.vars[0], p.name, row.vars[1], row.region);
    }
    // Materialise an ordinary callee with its original creation metadata.
    const method_type = try arrow(s, row.vars[0], row.vars[1], p.effect_edge);
    const wanted = try s.evidence.add(s.cx.gpa, .{
        .method = p.name,
        .receiver = row.vars[0],
        .method_type = method_type,
        .origin = row.region,
        .kind = .dot_call,
        .decl = p.decl,
        .parent = .none,
        .seq = row.seq - 1,
        .frame = row.frame,
        .field_ok = true,
    });
    try s.evidence.callees.append(s.cx.gpa, .{ .inst = row.region, .wanted = wanted });
    const r = s.obligations.rowPtr(id);
    r.kind = .nullary_dot;
    r.index = wanted.int();
    r.vars[1] = method_type;
    if (s.recursive_frames != 0) try Recursion.row(s, id);
    if (content == .flex and !(content.flex.kind == .number and Resolve.isWellKnownName(p.name)))
        return Instances.fieldCall(s, wanted, row.vars[0]);
    return Resolve.step(s, wanted, true);
}

fn isRecord(c: TypeStore.Content) bool {
    return c == .structure and (c.structure == .record or c.structure == .empty_record);
}

fn cheap(s: *Solve, root: Var, name: InternPool.Symbol) Error!bool {
    if (s.resolver.steps >= Resolve.step_budget - 1 or !s.store().proved(root)) return false;
    if (s.evidence.isRejected(root, .{ .method = name, .derives = Resolve.isWellKnownName(name) })) return false;
    if (std.debug.runtime_safety) try Walk.assertProved(s.store(), &s.stacks, s.cx.gpa, root);
    return true;
}

fn arrow(s: *Solve, receiver: Var, result: Var, effect_edge: u32) Error!Var {
    const params = try s.store().addVars(&.{receiver});
    const v = try s.fresh(.{ .structure = .{ .func = .{ .params = params, .result = result } } });
    if (effect_edge != Effects.none) {
        if (s.cx.effects) |effects| effects.edges.items[effect_edge].a = v;
    }
    return v;
}
