//! L10: what a call's writes rely on of its callee's `req`
//! (`docs/design/ownership-v2.md` §2.11.2 item 4, *A list's write beside a
//! record's*, *a record's write beside a list's*). A callee's `req` is one
//! selection for all of its writes. In the record pass (§2.11.5) a record's
//! own object is in it. A list's write does not fail there for a pair that
//! only a record's write asks, and a record's write does not fail for a
//! pair of two lists' storage. The list pass reads `req` once.
//!
//! Obligations kept here: O14's call half for a list beside a record: each
//! written list is still asked apart from every other occurrence, and each
//! record's object from every occurrence that can be a record's.

const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Update = @import("Update.zig");
const Distinct = @import("Distinct.zig");
const MovedReq = @import("MovedReq.zig");

const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// The callee's `req` on call `q`'s arguments: `[0]` what a record's write relies on, `[1]` what a list's
/// write relies on. Both are the contract's own reading unless that is `no` in the record pass. Then a
/// list's write asks each plain occurrence at a record's own object apart, and a record's write asks each
/// plain occurrence at a list's own storage apart: an apart occurrence keeps its pairs with every plain
/// occurrence, and its pairs with another apart occurrence are not asked. An occurrence whose slot's kind
/// no place says stays plain for both.
pub fn of(ev: *Relation.Eval, call: Value.Call, q: u32) Relation.Error![2]Cond {
    const c = try ev.contracts.cond(ev.arena, ev.contracts.head(call.contract).req);
    const whole = try on(ev, call, c, q);
    if (!whole.no or c.no or !ev.f.records) return .{ whole, whole };
    const params: []const Place.PlaceId = if (ev.code_sig != null and call.code != none) (try ev.code_sig.?.of(ev.code_sig.?.ctx, call.code)).params else &.{};
    const sels: [2][]u64 = .{ try ev.arena.dupe(u64, c.sel), try ev.arena.dupe(u64, c.sel) };
    var n: [2]usize = .{ 0, 0 };
    for (c.sel, 0..) |o, i| {
        if (Contract.isFed(o) or Contract.isApart(o) or Contract.isDeep(o)) continue;
        const j = Contract.occParam(o);
        const words = ev.f.slots.relWords(Contract.occRel(o));
        const kinds: [2]?Place.Kind = .{ if (j < params.len) Update.kindBelow(ev.f, params[j], words) else null, if (j < call.args.len) Update.kindAt(ev.f, call.args[j], words) else null };
        // A record's object is apart for a list's write (`[1]`), a list's storage for a record's (`[0]`).
        const k: usize = if (kinds[0] == .record or kinds[1] == .record) 1 else if (kinds[0] == .list or kinds[1] == .list) 0 else continue;
        sels[k][i] |= Contract.apart_bit;
        n[k] += 1;
    }
    if (@import("Mutate.zig").on(.list_req_whole)) n[1] = 0;
    if (@import("Mutate.zig").on(.record_req_whole)) n[0] = 0;
    var out: [2]Cond = .{ whole, whole };
    for (&out, sels, n) |*x, sel, m| if (m != 0) {
        x.* = try on(ev, call, try Cond.of(ev.f.account, sel), q);
    };
    return out;
}

/// `c` moved onto the frame's parameters (`MovedReq`), else instantiated (`Distinct.reqOn`).
fn on(ev: *Relation.Eval, call: Value.Call, c: Cond, q: u32) Relation.Error!Cond {
    return (try MovedReq.of(ev, call, c)) orelse try Distinct.reqOn(ev, c, q);
}
