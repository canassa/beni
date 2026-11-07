//! L9: a virtual call (`docs/design/ownership-v2.md` §2.11.3, *A virtual call
//! is an evaluation's*): a label's application to a known code, with its
//! answer's root and its supplies'. `Eval` reads its contract.
//!
//! Obligations kept here: O1 (a code whose places no step can name is unknown).

const std = @import("std");
const Ids = @import("Ids.zig");
const BelowSize = @import("BelowSize.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const WalkContext = @import("WalkContext.zig");

const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;
const none: u32 = Ids.none_int;

/// Call `q`'s label `l` applied to code `code`, the closure `fv`: its index in `f.calls`.
pub fn make(f: *Value.Frame, ctx: WalkContext.Context, q: u32, l: Contract.Label, code: u32, fv: u32) Error!u32 {
    const gpa = f.gpa;
    const call = f.calls.items[q];
    const sig = try ctx.codeSig(ctx.ctx, code);
    // The supplies and the answer at the call site's function type, never
    // the code's own: a polymorphic code (`a → a`) has a type variable's
    // place, which no step below it can name (`.values` of an `R → R` label).
    // The site is the argument's instruction, else the type the label's
    // origin call has its callee at (a capture has no instruction at the
    // call, #1758). Where neither is to hand, a code with such a place is
    // unknown.
    var site: std.ArrayList(PlaceId) = .empty;
    defer site.deinit(gpa);
    var site_result: ?PlaceId = if (f.slots.relWords(l.slot).len == 0 and l.j < call.arg_insts.len) try ctx.siteSig(ctx.ctx, call.arg_insts[l.j], &site) else null;
    if (site_result == null or site.items.len != sig.own) {
        site.clearRetainingCapacity();
        site_result = try ctx.originSig(ctx.ctx, l.origin, &site);
    }
    const at_site = site_result != null and site.items.len == sig.own;
    var wild = false;
    if (!at_site) for (sig.params[0..@min(sig.own, sig.params.len)]) |p| {
        wild = wild or try BelowSize.wildBelow(gpa, f.places, p);
    };
    if (!at_site) wild = wild or try BelowSize.wildBelow(gpa, f.places, sig.result);
    const vi: u32 = @intCast(f.calls.items.len);
    var args: std.ArrayList(u32) = .empty;
    defer args.deinit(gpa);
    for (0..sig.own) |k| {
        const si: u32 = @intCast(f.supplies.items.len);
        const root = try f.addRoot(.supply, si, if (at_site) site.items[k] else if (k < sig.params.len) sig.params[k] else .none);
        try f.supplies.append(gpa, .{ .call = q, .virtual = vi, .k = @intCast(k), .root = root });
        try args.append(gpa, try f.refRoot(root));
    }
    try args.appendSlice(gpa, f.kidsOf(f.val(fv)));
    const root = try f.addRoot(.call, vi, if (at_site) site_result.? else sig.result);
    try f.calls.append(gpa, .{ .inst = call.inst, .point = call.point, .args = try f.mkKids(args.items), .arg_insts = &.{}, .root = root, .code = if (wild) none else code, .virtual = true, .callee_val = fv });
    return vi;
}
