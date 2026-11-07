//! L13: how a block names what is local to a module (`docs/design/ownership-v2.md`
//! §3.6): a field by its name, a declaration by its qualified name. Split from
//! `Block` (#1991).
//!
//! Obligations kept here: none of §2.14's directly.

const Contract = @import("Contract.zig");

pub fn supply(l: *Contract.Draft.DraftLabel, arena: @import("std").mem.Allocator, w: u32) !*Contract.Draft.DraftSupply {
    const s = try l.supplyOf(arena, w & 0x3fff_ffff);
    s.each, s.walk = .{ w >> 31 != 0, (w >> 30) & 1 != 0 };
    return s;
}
