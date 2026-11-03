//! L8: a callee's tree taken as one node at a call (`docs/design/ownership-v2.md`
//! §2.10 *Read-off*, *A parameter's path grafted*; §2.11.2; #1225, #1714).
//! When an argument is one of the caller's parameters whole, at the callee's
//! parameter's own place, the callee's slots of that parameter are the
//! caller's slots of its parameter, step for step: the same `Slots.Rel`. So
//! the callee's result tree is the caller's subtree at the call, its
//! parameters renamed, and its condition's occurrences are the caller's,
//! renamed. Neither is replayed onto the argument a step at a time and named
//! again, so the work at such a call is constant in the length of the
//! callee's paths.
//!
//! Obligations kept here: none of §2.14's directly (each renamed arrival or
//! occurrence names exactly the objects its instantiation names: the same
//! parameter's objects at the same steps from its root, at a place where
//! the steps are the same slots).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// The caller's parameter call `call`'s argument `j` is, whole at its root
/// and at the place of the callee's parameter `j` (`params`), or null.
fn argParam(ev: *Relation.Eval, call: u32, params: []const Ids.PlaceId, j: u32) ?u32 {
    const f = ev.f;
    const cl = f.calls.items[call];
    if (j >= cl.args.len or j >= params.len) return null;
    const x = f.val(cl.args[j]);
    if (x.kind != .ref or x.family != Slots.empty) return null;
    const r = f.roots.items[x.root];
    if (r.kind != .param or f.pos.items[x.pos].slot != r.path) return null;
    if (f.places.pathPlace(r.path) != params[j]) return null;
    return r.a;
}

/// The callee's signature when call `call`'s contract is fixed: a module
/// code's, read whole, not a member being solved now.
fn settled(ev: *Relation.Eval, call: u32) Error!?Relation.Sig {
    const cl = ev.f.calls.items[call];
    const cs = ev.code_sig orelse return null;
    if (cl.virtual or cl.code == none) return null;
    const c = ev.contractOf(call) orelse return null;
    if (ev.contracts.head(c).flags.pessimistic) return null;
    if (ev.live) |lv| if (lv.draftRes(lv.ctx, cl.code) != null) return null;
    return try cs.of(cs.ctx, cl.code);
}

/// The callee's arrivals at slot `sl` of call `call`'s result, as the
/// caller's (`ReadOff.describeOne`): atoms as they are, each parameter
/// arrival at the slot itself renamed to the caller's parameter
/// (`argParam`), deep only at a type variable's slot, as the read-off
/// says a parameter's slot there. False, `out` untouched, where an
/// arrival is a label's, on another argument, or open above the slot; a
/// call none of whose arguments is a parameter whole, or a slot whose key
/// is made already, is not read at all.
pub fn slotArrivals(ev: *Relation.Eval, call: u32, sl: Ids.PathId, out: *std.ArrayList(Contract.Arrival)) Error!bool {
    // A slot instantiated already is read as its key holds it.
    if (ev.inst_memo.get(.{ call, sl.int(), none }) != null) return false;
    const sig = (try settled(ev, call)) orelse return false;
    for (0..sig.params.len) |j| {
        if (argParam(ev, call, sig.params, @intCast(j)) != null) break;
    } else return false;
    const f = ev.f;
    // The slot's steps read off its path, uncharged: a test that fails pays
    // nothing the projection pays again; one that passes pays `relOf` below.
    var steps: std.ArrayList(u32) = .empty;
    defer steps.deinit(ev.gpa());
    var at = sl;
    while (f.places.pathParent(at) != .none) : (at = f.places.pathParent(at)) try steps.append(ev.gpa(), f.places.pathStep(at).word());
    std.mem.reverse(u32, steps.items);
    const words = steps.items;
    const var_slot = f.places.kind(f.places.pathPlace(sl)) == .@"var";
    var hits: std.ArrayList(Contract.Hit) = .empty;
    defer hits.deinit(ev.gpa());
    try ev.hitsAt(ev.contracts.head(ev.contractOf(call).?).res_root, words, &hits);
    const start = out.items.len;
    // What a failed test reads, the instantiation reads and pays for next.
    for (hits.items) |hit| for (hit.arrivals) |a0| {
        var a = a0;
        const ok = switch (a.kind) {
            .fresh, .top, .shared => true,
            .cb => false,
            .param => hit.depth == words.len and a.deep == var_slot and if (argParam(ev, call, sig.params, a.j)) |m| blk: {
                a.j = m;
                break :blk true;
            } else false,
        };
        if (!ok) {
            out.shrinkRetainingCapacity(start);
            return false;
        }
        try out.append(ev.gpa(), a);
    };
    _ = try f.slots.relOf(ev.gpa(), ev.account(), f.places, sl);
    try ev.charge(.inspection, @intCast(@max(1, out.items.len - start)));
    return true;
}

/// A callee's condition `c` on call `call`'s arguments as the caller's own:
/// each occurrence's parameter renamed (`argParam`), where every one is on
/// such an argument and no two parameters on one; else null.
pub fn sel(ev: *Relation.Eval, c: Cond, call: u32) Error!?Cond {
    const sig = (try settled(ev, call)) orelse return null;
    const g = ev.gpa();
    // Each callee parameter's caller parameter, and whose that one is:
    // two parameters handed one value are that value twice.
    var map: Ids.FixedDict(1) = .{};
    defer map.deinit(g);
    var owner: Ids.FixedDict(1) = .{};
    defer owner.deinit(g);
    const out = try ev.arena.alloc(u64, c.sel.len);
    // A failed test reads what `instSel` reads and pays for next;
    // `Cond.of` pays for the renamed selection.
    for (c.sel, out) |o, *x| {
        const j = Contract.occParam(o);
        const got = try map.getOrPut(g, .{j});
        if (!got.found_existing) {
            got.value_ptr.* = argParam(ev, call, sig.params, j) orelse return null;
            const ow = try owner.getOrPut(g, .{got.value_ptr.*});
            if (ow.found_existing) return null;
            ow.value_ptr.* = j;
        }
        x.* = (o & ~(@as(u64, 0x1fff_ffff) << 32)) | (@as(u64, got.value_ptr.*) << 32);
    }
    return try Cond.of(ev.account(), out);
}

/// The path a demand's text names (`Walk.Demand.write_rel`): steps `rel`
/// replayed below `root`, its first canonical name; `root` itself for no
/// steps. Made when the line is printed, on an account of its own: the
/// text's work, never the check's.
pub fn textPath(places: *Place.Table, slots: *const Slots.Table, gpa: std.mem.Allocator, root: Ids.PathId, rel: Slots.Rel) std.mem.Allocator.Error!Ids.PathId {
    if (rel == Slots.root or root == .none) return root;
    var account: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
    defer account.deinit(gpa);
    var ps: std.ArrayList(u32) = .empty;
    defer ps.deinit(gpa);
    Slots.replay(gpa, &account, places, root, slots.relWords(rel), &ps) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else .none;
    return if (ps.items.len != 0) .from(ps.items[0]) else .none;
}
