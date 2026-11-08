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
    // The supplies and the answer at the call site's function type, the
    // argument's instruction's. Else at the code's own type, unless a
    // polymorphic code (`a → a`) has a type variable's place there, which no
    // step below it can name (`.values` of an `R → R` label). Then at the type
    // the label's origin call has its callee at (a capture has no instruction
    // at the call, #1758): a callee's view, whose row stands for what the code
    // names (§2.1, #2172). Where neither is to hand, such a code is unknown.
    var site: std.ArrayList(PlaceId) = .empty;
    defer site.deinit(gpa);
    var site_result: ?PlaceId = if (f.slots.relWords(l.slot).len == 0 and l.j < call.arg_insts.len) try ctx.siteSig(ctx.ctx, call.arg_insts[l.j], &site) else null;
    var at_site = site_result != null and site.items.len == sig.own;
    const at_call = at_site;
    var wild = !at_site and try BelowSize.wildSig(gpa, f.places, sig.params[0..@min(sig.own, sig.params.len)], sig.result);
    if (wild) {
        site.clearRetainingCapacity();
        site_result = try ctx.originSig(ctx.ctx, l.origin, &site);
        at_site = site_result != null and site.items.len == sig.own;
        wild = !at_site;
    }
    // A type variable's place names nothing below it, so a supply there was written as leaves at no level a
    // reader sees (#2222). Off the call site, a supply sits where the frame names its structure: at the type
    // the frame makes the closure at, else at the code's own (§2.1, *A callback*).
    var made: std.ArrayList(PlaceId) = .empty;
    defer made.deinit(gpa);
    const fx = f.val(fv);
    const made_at = !at_call and fx.kind == .built and fx.form == .closure and fx.site != none and
        (try ctx.siteSig(ctx.ctx, fx.site, &made)) != null and made.items.len == sig.own;
    const vi: u32 = @intCast(f.calls.items.len);
    var args: std.ArrayList(u32) = .empty;
    defer args.deinit(gpa);
    for (0..sig.own) |k| {
        const si: u32 = @intCast(f.supplies.items.len);
        const own: PlaceId = if (k < sig.params.len) sig.params[k] else .none;
        const old: PlaceId = if (at_site) site.items[k] else own;
        const at = if (at_call or !try BelowSize.wildBelow(gpa, f.places, old)) old else if (made_at and !try BelowSize.wildBelow(gpa, f.places, made.items[k])) made.items[k] else if (own != .none and !try BelowSize.wildBelow(gpa, f.places, own)) own else old;
        const root = try f.addRoot(.supply, si, at);
        try f.supplies.append(gpa, .{ .call = q, .virtual = vi, .k = @intCast(k), .root = root });
        try args.append(gpa, try f.refRoot(root));
    }
    try args.appendSlice(gpa, f.kidsOf(f.val(fv)));
    const root = try f.addRoot(.call, vi, if (at_site) site_result.? else sig.result);
    try f.calls.append(gpa, .{ .inst = call.inst, .point = call.point, .args = try f.mkKids(args.items), .arg_insts = &.{}, .root = root, .code = if (wild) none else code, .virtual = true, .callee_val = fv });
    return vi;
}
