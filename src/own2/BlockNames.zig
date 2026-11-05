//! L13: how a block names what is local to a module (`docs/design/ownership-v2.md`
//! §3.6): a field by its name, a declaration by its qualified name. Split from
//! `Block` (#1991).
//!
//! Obligations kept here: none of §2.14's directly.

const Contract = @import("Contract.zig");

/// How the writer names a field rank, a top-level value and an origin, as
/// string indices of the block's table.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) u32,
    /// `(module, declaration)` as a qualified name.
    decl: *const fn (ctx: *anyopaque, md: [2]u32) u32,
};

/// The reader's inverse: a field name string to this module's rank, a
/// qualified name string to `(module, declaration)`.
pub const Remap = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, string: u32) ?u32,
    decl: *const fn (ctx: *anyopaque, string: u32) ?[2]u32,
};

pub fn supply(l: *Contract.Draft.DraftLabel, arena: @import("std").mem.Allocator, w: u32) !*Contract.Draft.DraftSupply {
    const s = try l.supplyOf(arena, w & 0x3fff_ffff);
    s.each, s.walk = .{ w >> 31 != 0, (w >> 30) & 1 != 0 };
    return s;
}
