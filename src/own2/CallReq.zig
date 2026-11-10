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

const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const ReqKinds = @import("ReqKinds.zig");
const Distinct = @import("Distinct.zig");
const MovedReq = @import("MovedReq.zig");

const Cond = Contract.Cond;

/// The callee's `req` on call `q`'s arguments: `[0]` what a record's write relies on, `[1]` what a list's
/// write relies on. Both are the contract's own reading unless that is `no` in the record pass. Then each
/// kind's write reads it with the occurrences of the other kind asked apart (`ReqKinds.of`).
pub fn of(ev: *Relation.Eval, call: Value.Call, q: u32) Relation.Error![2]Cond {
    const c = try ev.contracts.cond(ev.arena, ev.contracts.head(call.contract).req);
    const whole = try on(ev, call, c, q);
    var out: [2]Cond = .{ whole, whole };
    if (!whole.no or c.no or !ev.f.records) return out;
    if (!@import("Mutate.zig").on(.record_req_whole)) if (try ReqKinds.of(ev, call, c, true)) |x| {
        out[0] = try on(ev, call, x, q);
    };
    if (!@import("Mutate.zig").on(.list_req_whole)) if (try ReqKinds.of(ev, call, c, false)) |x| {
        out[1] = try on(ev, call, x, q);
    };
    return out;
}

/// `c` moved onto the frame's parameters (`MovedReq`), else instantiated (`Distinct.reqOn`).
fn on(ev: *Relation.Eval, call: Value.Call, c: Cond, q: u32) Relation.Error!Cond {
    return (try MovedReq.of(ev, call, c)) orelse try Distinct.reqOn(ev, c, q);
}
