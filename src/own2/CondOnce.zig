//! L7: a call's condition instantiated once (`docs/design/ownership-v2.md`
//! §2.9.1, *Apart occurrences*; §4.1; #2418), for `PlainReach.instCondMixed`:
//! the evaluation is `e`.
//!
//! Obligations kept here: none of §2.14's directly: a value kept is the value
//! the instantiation gave (O14 is the instantiation's).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");

const Cond = Contract.Cond;
const Error = Ids.ChargeError;

/// `instSel(e, c, call)`, each `(call, mode, keeping, selection)` once an
/// evaluation. A check asks a call's mixed condition again at each round in
/// which the call's group gains entries, and each asking instantiated the
/// whole chain of calls below it again: a chain of n calls that thread one
/// record and push onto a list field of it cost 2ⁿ checks. A value computed
/// under a cycle's cut is kept, as `instCond`'s is: the cut reads the
/// pessimistic `no` (§2.9.2, *A value under another cut*). A strict check
/// that hoped (`Distinct.hoped`) hopes again when its value is taken.
pub fn of(e: anytype, c: Cond, call: u32, instSel: anytype) Error!Cond {
    if (c.no or c.sel.len == 0 or @import("Mutate.zig").on(.mixed_memo_off)) return instSel(e, c, call);
    try e.charge(.cond, @intCast(2 + c.sel.len));
    const key = try e.arena.alloc(u64, c.sel.len + 1);
    key[0] = @as(u64, call) << 3 | @as(u64, @intFromBool(e.keeping)) << 2 | @as(u64, switch (e.read_mode) {
        .ask => 0,
        .strict, .hope => 1,
        .reading => 2,
    });
    @memcpy(key[1..], c.sel);
    if (e.mixed_memo.get(std.mem.sliceAsBytes(key))) |m| {
        if (m.hoped and e.read_mode == .strict) e.read_mode = .hope;
        return m.cond;
    }
    const strict = e.read_mode == .strict;
    const got = try instSel(e, c, call);
    try e.mixed_memo.put(e.gpa(), std.mem.sliceAsBytes(key), .{ .cond = got, .hoped = strict and e.read_mode == .hope });
    return got;
}
