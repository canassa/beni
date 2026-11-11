//! L10: what a call's writes rely on of its callee's `req`
//! (`docs/design/ownership-v2.md` §2.11.2 item 4, *A list's write beside a
//! record's*). A callee's `req` is one selection for all of its writes. In
//! the record pass (§2.11.5) a record's own object is in it. A list's write
//! does not fail there for a pair that only a record's write asks: the
//! report would say that failure as a second refusal, at the list, beside
//! the record's own. The list pass reads `req` once.
//!
//! Obligations kept here: O14's call half for a list beside a record: each
//! written list is still asked apart from every other occurrence.

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

/// The callee's `req` on call `q`'s arguments: `[0]` as the contract has it,
/// what a record's write relies on; `[1]` what a list's write relies on. They
/// differ only where the first is `no` and the selection has a plain
/// occurrence at a record's own object. A list's write asks that occurrence
/// apart: its pairs with every plain occurrence stay, and its pairs with
/// another record's object or with an apart occurrence are not asked.
pub fn of(ev: *Relation.Eval, call: Value.Call, q: u32) Relation.Error![2]Cond {
    const c = try ev.contracts.cond(ev.arena, ev.contracts.head(call.contract).req);
    const whole = try on(ev, call, c, q);
    if (!whole.no or c.no or !ev.f.records or @import("Mutate.zig").on(.list_req_whole)) return .{ whole, whole };
    const params: []const Place.PlaceId = if (ev.code_sig != null and call.code != none) (try ev.code_sig.?.of(ev.code_sig.?.ctx, call.code)).params else &.{};
    const sel = try ev.arena.dupe(u64, c.sel);
    var n: usize = 0;
    for (sel) |*o| {
        if (Contract.isFed(o.*) or Contract.isApart(o.*) or Contract.isDeep(o.*)) continue;
        const j = Contract.occParam(o.*);
        const words = ev.f.slots.relWords(Contract.occRel(o.*));
        if (!Update.recordParam(ev.f, params, j, words) and !(j < call.args.len and Update.recordAt(ev.f, call.args[j], words))) continue;
        o.* |= Contract.apart_bit;
        n += 1;
    }
    return .{ whole, if (n == 0) whole else try on(ev, call, try Cond.of(ev.f.account, sel), q) };
}

/// `c` moved onto the frame's parameters (`MovedReq`), else instantiated (`Distinct.reqOn`).
fn on(ev: *Relation.Eval, call: Value.Call, c: Cond, q: u32) Relation.Error!Cond {
    return (try MovedReq.of(ev, call, c)) orelse try Distinct.reqOn(ev, c, q);
}
