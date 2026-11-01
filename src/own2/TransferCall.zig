//! L10: call application (`docs/design/ownership-v2.md` §2.11): a call's
//! class at its instantiation, its demands per write route, the write's
//! other paths, and the groups a route that stopped at a parameter's leaf
//! leaves for after the walk. `Of(Frame)` is this part's methods over the
//! frame `Transfer.zig` declares; `Transfer.zig` binds them by name (§5).
//! It calls `TransferFrame`, `TransferBeside` and `TransferConstruct`.
//!
//! Obligations kept here: none of §2.14's directly; a call's result is
//! the class's, which `Calls` applies (O1, O5, O14 are its).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Demands = @import("Demands.zig");
const Calls = @import("Calls.zig");
const Bir = @import("../bir/Bir.zig");
const Value = Demands.Value;
const Beside = Calls.Beside;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;
const Inst = Bir.Inst;

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        // ---- calls -------------------------------------------------------------------

        pub fn call(f: *Frame, i: u32, callee_inst: u32, arg_insts: []const Inst.Index) Error!Value {
            // §4.1's call view: the callee's class at this call and its graft.
            const kernel = try f.account().enter(f.gpa, .{ .atom = i, .role = .call_view });
            defer f.account().leave(kernel);
            const at = try f.placeOf(i);
            switch (try f.ctx.callee(f.ctx.ctx, i)) {
                .unbuilt => {
                    f.markUnbuilt(i);
                    return f.topValue(at);
                },
                .harmless => {
                    for (arg_insts) |a| try f.consume(a.int(), i, .whole, .none);
                    return f.nothing(at);
                },
                .ctor => |ord| {
                    var parts: std.ArrayList(u32) = .empty;
                    defer parts.deinit(f.gpa);
                    var steps: std.ArrayList(Step) = .empty;
                    defer steps.deinit(f.gpa);
                    for (arg_insts, 0..) |a, k| {
                        try f.consume(a.int(), i, .whole, .none);
                        try parts.append(f.gpa, a.int());
                        try steps.append(f.gpa, try f.env.places.ctorStep(f.gpa, f.account(), ord, @intCast(k)));
                    }
                    return f.container(i, parts.items, steps.items, false);
                },
                .class => |class| {
                    const uses = f.sums.paramUses(class);
                    var argv: std.ArrayList(Value) = .empty;
                    defer argv.deinit(f.gpa);
                    for (arg_insts, 0..) |a, k| {
                        try f.consume(a.int(), i, .call, if (k < uses.len) uses[k] else .none);
                        try argv.append(f.gpa, f.val(a.int()).value);
                    }
                    // The graft copies the callee's class over the arguments' structure:
                    // named growth until §4.1's call view by reference (#1097, S3b).
                    const graft = try f.account().enter(f.gpa, null);
                    f.calls.result_place = at;
                    const applied = Calls.apply(f.env, f.sums, class, argv.items, i, &f.calls) catch |e| {
                        f.account().leave(graft);
                        return e;
                    };
                    f.account().leave(graft);
                    if (f.ctx.onCall) |on| try on(f.ctx.ctx, i, argv.items);
                    // The callee's `xreq` is discharged on the call's first write, and
                    // reported there (§2.11 step 7); a call that writes nothing owes
                    // it as the frame's.
                    const first_demand = f.demands.items.len;
                    // What the use shapes let escape and write, one route per path
                    // of their pair graph with the argument (#1356), in growth.
                    var routes: Calls.Routes = .{ .env = f.env };
                    defer routes.deinit();
                    const n_args = @min(uses.len, arg_insts.len);
                    for (uses[0..n_args], 0..) |u, k| {
                        const esc_walk = try f.account().enter(f.gpa, null);
                        defer f.account().leave(esc_walk);
                        try routes.start(u, argv.items[k].node, .escapes);
                        while (try routes.next()) |e| if (try f.positionsAt(argv.items[k], e.steps)) |pos|
                            try f.escapes.append(f.gpa, .{ .node = pos.node, .point = i });
                    }
                    for (applied.escaped) |n| try f.escapes.append(f.gpa, .{ .node = n, .point = i });
                    const answer = applied.result;
                    // The children beside the writes' paths, indexed once for
                    // every write of this call (#1334).
                    var beside: Beside = .{};
                    defer beside.deinit(f.gpa);
                    // A route that stops at the caller's own parameter leaf is a
                    // group, expanded after the walk (§2.11 item 3, #1412).
                    var snap: u32 = none;
                    for (uses[0..n_args], 0..) |use, param| {
                        try routes.startStops(use, argv.items[param].node, .writes, true);
                        while (true) {
                            // The callee's path is value-sized: growth chosen before its
                            // walks, never the call's lane (§4.1, *call view and direct
                            // obligation*; a write `depth` steps below its argument).
                            const base_walk = try f.account().enter(f.gpa, null);
                            const w = (try routes.next()) orelse break f.account().leave(base_walk);
                            if (w.stop) |st| {
                                f.account().leave(base_walk);
                                if (snap == none) {
                                    snap = @intCast(f.call_snaps.items.len);
                                    const args_at: u32 = @intCast(f.call_args.items.len);
                                    try f.call_args.appendSlice(f.gpa, arg_insts);
                                    try f.call_snaps.append(f.gpa, .{ .point = i, .callee_inst = callee_inst, .args = .{ .start = args_at, .len = @intCast(arg_insts.len) }, .first_slot = @intCast(first_demand) });
                                }
                                const start: u32 = @intCast(f.group_steps.items.len);
                                try f.group_steps.appendSlice(f.gpa, w.steps);
                                try f.groups.append(f.gpa, .{ .call = snap, .param = @intCast(param), .use = use, .node = st.node, .leaf = st.leaf, .value = st.value, .prefix = .{ .start = start, .len = @intCast(w.steps.len) }, .slot = @intCast(f.demands.items.len) });
                                continue;
                            }
                            const wsteps = w.steps;
                            const pos = try f.positionsAt(argv.items[param], wsteps);
                            f.account().leave(base_walk);
                            const base = pos orelse continue;
                            var others: std.ArrayList(u32) = .empty;
                            defer others.deinit(f.gpa);
                            for (arg_insts, 0..) |a, k| if (k != param) try others.append(f.gpa, a.int());
                            try f.demand(i, if (w.deep) .consumed else .writer, arg_insts[param].int(), base, others.items, callee_inst);
                            // Disjoint against every other path of the argument the
                            // callee touches (§2.11 item 3, R-5.1.5): a write at `.x`
                            // while `.y` is read or answered is one object written
                            // twice if the actual's `.x` and `.y` are one. One
                            // operand, by node (#1325).
                            try f.otherPaths(&beside, use, argv.items[param], wsteps, base, arg_insts[param].int(), w.deep);
                            // The write's path below the argument: the demand's text,
                            // and the part of the argument's local it writes, which
                            // a later read must reach to conflict (§2.8).
                            if (wsteps.len != 0) {
                                const dm = &f.demands.items[f.demands.items.len - 1];
                                const path_walk = try f.account().enter(f.gpa, null);
                                defer f.account().leave(path_walk);
                                dm.write_path = try f.extendPath(try f.env.places.rootPath(f.gpa, try f.placeOf(arg_insts[param].int())), wsteps);
                                if (dm.base_path != .none) dm.base_path = try f.extendPath(dm.base_path, wsteps);
                            }
                        }
                    }
                    if (snap != none) {
                        // Discharged on the call's first demand once its groups
                        // are expanded (`expandGroups`).
                        const s = &f.call_snaps.items[snap];
                        s.xreq = applied.xreq;
                        s.orig_end = @intCast(f.demands.items.len);
                    } else if (f.demands.items.len > first_demand) {
                        const dm = &f.demands.items[first_demand];
                        dm.relies = try f.env.conds.@"and"(f.gpa, f.env.charge, dm.relies, applied.xreq);
                    } else f.xreq = try f.env.conds.@"and"(f.gpa, f.env.charge, f.xreq, applied.xreq);
                    return answer;
                },
            }
        }
    };
}
