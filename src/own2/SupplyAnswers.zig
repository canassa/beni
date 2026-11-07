//! L11: a label's answer in another label's supply
//! (`docs/design/ownership-v2.md` §2.11.3, *An answer handed on*). A write
//! of that supply writes what the function answered. Called more than once
//! in the frame, the function may answer one object each time, so what
//! writes it relies on the answers being apart. A pass that closes a
//! callee's open entry (§2.11.3, *A pass closes what it describes*) relies
//! on `below` for the arrivals it does not describe.
//!
//! Obligations kept here: O14's label half for an answer handed on.

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const AnsOcc = @import("AnsOcc.zig");
const Forest = @import("Forest.zig");
const Eval = @import("Eval.zig");

const Allocator = std.mem.Allocator;
const Cond = Contract.Cond;
const Error = Eval.Error;

/// Whether a pass keeps entry `x` open: a `⊤` is unknown at every slot below
/// it, and a pass describes no structure of it (§2.1, a fold).
pub fn staysOpen(x: anytype) bool {
    for (x.arrivals) |a| if (a.kind == .top) return true;
    return false;
}

/// A pass at the call's function type closes `x`, an entry of callee supply
/// `su`: open with an arrival it did not describe, `su.below` must say `no`,
/// or a `fed` occurrence keep what the arrival holds described.
pub fn closesAtSite(e: *Eval.Evaluation, su: Contract.Supply, x: anytype, n_args: usize) Error!void {
    if (!std.debug.runtime_safety or !x.open) return;
    const c = try e.contracts.cond(e.ev.arena, su.below);
    for (c.sel) |o| if (Contract.isFed(o) and !AnsOcc.is(o)) return;
    for (x.arrivals) |a| std.debug.assert(c.no or a.kind == .fresh or (a.kind == .param and a.j < n_args));
}

/// Each supply that holds the answer of another label: where that label's
/// function runs more than once in the frame, its answers must be apart.
pub fn repeated(e: *Eval.Evaluation, d: *Contract.Draft, arena: Allocator) Error!void {
    if (@import("Mutate.zig").on(.repeated_off)) return;
    const f = e.fr();
    var arrs: std.ArrayList(Contract.Arrival) = .empty;
    for (d.labels.items, 0..) |*g, gi| for (g.supplies.items) |*sup| {
        arrs.clearRetainingCapacity();
        for (sup.res.items.items) |rs| {
            if (rs.node == 0) try arrs.append(arena, rs.a) else try Forest.arrivalsOf(&e.contracts.trees, arena, f.places, rs.node, &arrs);
        }
        for (arrs.items) |a| {
            if (a.kind != .cb or a.j == gi) continue;
            const fl = d.labels.items[a.j];
            var runs: u32 = 0;
            for (d.labels.items) |o| if (o.j == fl.j and o.slot == fl.slot) {
                runs += @as(u32, @backingInt(o.calls));
            };
            if (runs < 2) continue;
            const one = fl.supplies.items.len == 1 and fl.supplies.items[0].kept.items.len == 0;
            const run = try arena.alloc(u64, 1);
            run[0] = Contract.occFed(fl.j, fl.slot, if (one) fl.supplies.items[0].k else Contract.fresh_arg);
            sup.cond = try Cond.conj(arena, f.account, sup.cond, try Cond.of(f.account, run));
            if (one) sup.cond = try Cond.conj(arena, f.account, try Cond.conj(arena, f.account, sup.cond, fl.supplies.items[0].cond), fl.supplies.items[0].below);
        }
    };
}
