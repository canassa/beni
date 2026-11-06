//! L12: what one step of a block is written to and read from
//! (`docs/design/ownership-v2.md` §3.6), split from `Block`: its names, its word
//! cursor and the tables a step is re-interned in, concrete, so `BlockStep` reaches
//! nothing above it.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

pub const Error = Ids.ChargeError || error{BadBlock};

/// A step's names as a block's strings: a field's rank to its name string, a
/// `(module, declaration)` to its qualified name string.
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

/// Where a step's words go.
pub const Out = struct {
    gpa: Allocator,
    out: *std.ArrayList(u32),
    places: *const Place.Table,
    names: Names,
};

/// A block's words, read once in order.
pub const Cursor = struct {
    words: []const u32,
    at: usize = 0,

    pub fn next(c: *Cursor) Error!u32 {
        if (c.at >= c.words.len) return error.BadBlock;
        c.at += 1;
        return c.words[c.at - 1];
    }

    /// A count, no more than the block's words.
    pub fn count(c: *Cursor) Error!u32 {
        const n = try c.next();
        return if (n > c.words.len) error.BadBlock else n;
    }
};

/// Where a step's words come from, and the tables it is re-interned in.
pub const In = struct {
    cur: *Cursor,
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    places: *Place.Table,
    remap: Remap,
    /// Per string the block's table names: its index, for re-encoding.
    field_string: *Ids.FixedDict(1),
};
