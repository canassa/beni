//! L6: whether a prepend may answer its base's own array, split from
//! `Relation` (`docs/design/ownership-v2.md` §2.3.4, *A deferred storage*;
//! §2.13.2; §2.13.6, `prepended`). Core's `cons` answers the base's array
//! only by a re-cons: when the item put in front is `Js.same` as the element
//! stored just before the base's view.
//!
//! Obligations kept here: O1 (a prepend's storage names the base's array
//! wherever the item may be that element).

const std = @import("std");
const Ids = @import("Ids.zig");

const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;

/// The flag of a prepend's spread kid when the instruction `inst` of the
/// front before it is a call: the prepend itself computes that front, so
/// no other value of the frame holds what the call made (`madeByFront`).
pub fn frontFlag(inst: u32) u32 {
    return 1 | (inst + 1) << 1;
}

/// The base word of a prepend's value whose last front is instruction
/// `inst`, of BIR tag `tag` (a tag no front has when there is none): 0, no
/// base storage at all, when the prepend itself computes that front as a
/// list, record or tuple literal, a new object that nothing else holds;
/// else `over`, and a call there is marked in the spread kid's flag.
pub fn front(tag: anytype, inst: u32, flags: []u32, over: u32) u32 {
    switch (tag) {
        .list, .tuple, .record => return 0,
        .call, .method_call => flags[flags.len - 1] = frontFlag(inst),
        else => {},
    }
    return over;
}

/// Whether prepend `x` may answer its base's own array. It cannot where
/// every object of the item put in front was made after the base (a
/// literal, a call's fresh objects): such an object is none of the base's
/// (`PrependFresh`). Nor where the front is a call the prepend computes and
/// its result is a list or a record that call made: nothing but the prepend
/// holds it, so no array has it as an element (`PrependFresh.bikeWars`).
pub fn may(e: anytype, x: anytype) Error!bool {
    if (@import("Mutate.zig").on(.recons_never)) return false;
    const saved = e.pass;
    e.pass = 0;
    defer e.pass = saved;
    const ks = e.f.kidsOf(x);
    if (ks.len < 2) return true;
    const item = ks[ks.len - 2];
    const flags = e.f.wordsOf(x.extra);
    if (flags.len == ks.len and flags[ks.len - 1] > 1 and try madeByFront(e, item, (flags[ks.len - 1] >> 1) - 1)) return false;
    const birth = bornAt(e, x.head - 1);
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(e.gpa());
    try e.leavesOf(item, 0, &ls);
    if (ls.items.len == 0) return true;
    var depth: u32 = 0;
    while (ls.items.len != 0) : (depth += 1) {
        if (depth > 4) return true;
        var next: std.ArrayList(u32) = .empty;
        defer next.deinit(e.gpa());
        for (ls.items) |li| {
            const l = e.f.leafAt(li);
            switch (l.kind) {
                .site => if (birth == none or l.atom <= birth) return true,
                .fresh => if (birth == none or e.f.calls.items[l.atom].point <= birth) return true,
                .ref => {
                    if (!e.expandable(l) or e.f.roots.items[l.root].kind != .call) return true;
                    if (birth == none or e.f.calls.items[e.f.roots.items[l.root].a].point <= birth) return true;
                    try e.expand(li, &next);
                },
                else => return true,
            }
        }
        std.mem.swap(std.ArrayList(u32), &ls, &next);
    }
    return false;
}

/// Whether `item` is the whole result of the call at instruction `inst`, a
/// list or a record, and its own object is one that call made and nothing
/// else: the callee kept none (an object it kept arrives as a host's too),
/// and the frame names the result nowhere but in the prepend. A tuple has
/// no storage of its own to ask, and a constructor's value may be unboxed
/// to a scalar, which `Js.same` compares by value: neither is taken.
fn madeByFront(e: anytype, item: u32, inst: u32) Error!bool {
    if (@import("Mutate.zig").on(.recons_front_any)) return true;
    const v = e.f.val(item);
    if (v.kind != .ref or v.place == .none) return false;
    const root = e.f.roots.items[v.root];
    if (root.kind != .call or e.f.calls.items[root.a].inst != inst) return false;
    switch (e.places().kind(v.place)) {
        .list, .record => {},
        else => return false,
    }
    var own: std.ArrayList(u32) = .empty;
    defer own.deinit(e.gpa());
    try e.storageOf(item, 0, &own);
    if (own.items.len == 0) return false;
    var made: std.ArrayList(u32) = .empty;
    defer made.deinit(e.gpa());
    for (own.items) |li| {
        const l = e.f.leafAt(li);
        if (l.kind != .ref or l.root != v.root or !e.expandable(l)) return false;
        try e.expand(li, &made);
    }
    if (made.items.len == 0) return false;
    for (made.items) |li| {
        const l = e.f.leafAt(li);
        if (l.kind != .fresh or l.atom != root.a) return false;
    }
    return true;
}

/// The point value `v` was made at: a parameter's before every point,
/// a call's at the call, a built one at its instruction; `none` unknown.
fn bornAt(e: anytype, v: u32) u32 {
    const x = e.f.val(v);
    return switch (x.kind) {
        .ref => switch (e.f.roots.items[x.root].kind) {
            .param => 0,
            .call => e.f.calls.items[e.f.roots.items[x.root].a].point,
            else => none,
        },
        .built => if (x.site != none) x.site else none,
        else => none,
    };
}
