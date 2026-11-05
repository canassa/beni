//! L8: a function value in a result (`docs/design/ownership-v2.md` §2.11.3,
//! *a function value in a result*). A called code `D@s` is one call of the
//! value at function slot `s` of `D`'s result: its parameters are the
//! function's own, `D`'s, and `self`, the value. A value that is a walked
//! call's result at such a slot is a closure of that code (`value`), so a
//! call of it is a code call and a label applied to it a virtual call. The
//! read-off of a called code keeps only what its last call does (`inLast`).
//!
//! Obligations kept here: O1 (a value this cannot name stays unknown code).

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");
const Contract = @import("Contract.zig");
const LabelChain = @import("LabelChain.zig");
const WalkContext = @import("WalkContext.zig");

const Error = Value.Error;
const none: u32 = Ids.none_int;

/// Marks a label whose origin is a called code's last call, which no call
/// instruction of the module has the type of (`Groups.originSig`).
pub const last_origin = Contract.last_origin;

/// Where each of a walk's lists ends and its last call's begin: all zero
/// for any other code, so that every list is read whole.
pub const Last = struct { calls: u32 = 0, demands: u32 = 0, escapes: u32 = 0, runs: u32 = 0, uses: u32 = 0, cbs: u32 = 0 };

/// What a walk of a called code adds to its body's.
pub const Input = struct {
    own_places: []const Ids.PlaceId,
    /// The function value's steps below the result.
    words: []const u32,
    /// The body's own result place (`Walk.Code.result_place` is the call's).
    body_result: Ids.PlaceId,
};

/// The closure value `fv` is when it is a walked call's result at a
/// function slot with a called contract, else null.
pub fn value(f: *Value.Frame, ctx: WalkContext.Context, contracts: *const Contract.Table, fv: u32) Error!?u32 {
    const x = f.val(fv);
    if (x.kind != .ref or x.family != Slots.empty) return null;
    const r = f.roots.items[x.root];
    if (r.kind != .call) return null;
    const c = f.calls.items[r.a];
    const rel = (try f.slots.relBelow(f.gpa, f.account, f.places, r.path, f.pos.items[x.pos].slot)) orelse return null;
    const head = if (c.code != none)
        ctx.calledOf(ctx.ctx, c.code, rel) orelse return null
    else if (c.contract != none)
        (contracts.calledOf(c.contract, rel) orelse return null) | WalkContext.fixed_bit
    else
        return null;
    const ks = try f.arena.alloc(u32, c.args.len + 1);
    @memcpy(ks[0..c.args.len], c.args);
    ks[c.args.len] = fv;
    return try f.mk(.{ .kind = .built, .form = .closure, .head = head, .place = x.place, .kids = ks });
}

/// Whether call `q` belongs to the walk's last call: it is that call, or a
/// virtual call under it. Every call does for any other code (`first` 0).
pub fn inLast(c: LabelChain.Chain, first: u32, walk_calls: u32, q: u32) bool {
    if (first == 0) return true;
    var x = q;
    while (x >= walk_calls) x = (LabelChain.virtualOuter(c, x) orelse return false)[0];
    return x >= first;
}
