//! L7: the atoms a result already holds by structure (`docs/design/
//! ownership-v2.md` §2.10 *Read-off*, amended 2026-11-02 for #1716): a wide
//! entry of a draft's result says its atom at every slot below its own, so
//! the read-off of a call's subtree below that slot need not describe the
//! atom again.
//!
//! Obligations kept here: none of §2.14's directly (`ReadOff` calls these;
//! what they skip is said already).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");

const Error = Value.Error;

/// The atoms a draft holds open at or above a result slot: fresh objects,
/// `⊤`, host objects, and up to `shared_max` shared values (any more are described as
/// before).
pub const Atoms = struct {
    fresh: bool = false,
    top: bool = false,
    host: bool = false,
    shared_n: u8 = 0,
    shared: [shared_max][2]u32 = undefined,

    pub const shared_max = 8;
};

/// The atoms that a wide entry of `res` at or above the result slot `q`
/// holds. One lookup in the draft, one record, as an arrival's is. A
/// committed tree joined in (`res.base`) is not read: what it holds is
/// described again, which says nothing less.
pub fn atoms(f: *Value.Frame, res: *const Contract.Draft.Res, q: Ids.PathId) Error!Atoms {
    try f.charge(.inspection, 1);
    const qw = f.slots.relWords(try f.slots.relOf(f.gpa, f.account, f.places, q));
    var held: Atoms = .{};
    for (res.items.items) |rs| {
        if (!rs.wide or rs.node != 0 or !std.mem.startsWith(u32, qw, f.slots.relWords(rs.slot))) continue;
        switch (rs.a.kind) {
            .fresh => held.fresh = true,
            .top => held.top = true,
            .host => held.host = true,
            .shared => if (held.shared_n < Atoms.shared_max) {
                held.shared[held.shared_n] = .{ rs.a.j, rs.a.slot };
                held.shared_n += 1;
            },
            else => {},
        }
    }
    return held;
}

/// Whether leaf `l` is an atom that `held` says already.
pub fn has(held: Atoms, l: Value.Leaf) bool {
    return switch (l.kind) {
        .site, .fresh => held.fresh,
        .top, .loan => held.top,
        .host => held.host,
        .shared => for (held.shared[0..held.shared_n]) |x| {
            if (x[0] == l.atom and x[1] == l.extra) break true;
        } else false,
        else => false,
    };
}
