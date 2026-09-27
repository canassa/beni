//! What every printer shares: the language list, what a module needed from
//! each language's libraries, and the per-module statistics of §5.3.

const std = @import("std");

pub const Lang = enum {
    beni,
    elm,
    gleam,
    roc,
    purescript,
    typescript,

    pub const all = [_]Lang{ .beni, .elm, .gleam, .roc, .purescript, .typescript };

    pub fn parse(s: []const u8) ?Lang {
        for (all) |l| if (std.mem.eql(u8, s, @tagName(l))) return l;
        return null;
    }
};

pub const LibUse = struct {
    prelude: bool = false,
    list_type: bool = false,
    list_nil: bool = false,
    list_cons: bool = false,
    list_filter: bool = false,
    foldable: bool = false,
    tuple_type: bool = false,
    tuple_ctor: bool = false,
    gleam_list: bool = false,
    gleam_int: bool = false,
};

pub const Stats = struct {
    tokens: u64 = 0,
    lines: u64 = 0,
    /// ML family: declarations printed with a signature. TypeScript: every
    /// annotation site written (parameter, return type, lambda parameter).
    annotations: u64 = 0,
    explicit_type_args: u64 = 0,
    invoked_arrows: u64 = 0,
    modules: u64 = 0,

    pub fn add(a: *Stats, b: Stats) void {
        a.tokens += b.tokens;
        a.lines += b.lines;
        a.annotations += b.annotations;
        a.explicit_type_args += b.explicit_type_args;
        a.invoked_arrows += b.invoked_arrows;
        a.modules += b.modules;
    }
};

/// Gleam's module names are lower case (§7.3): `Inf003` is `inf003`.
pub fn gleamModule(a: std.mem.Allocator, name: []const u8) []const u8 {
    const out = a.alloc(u8, name.len) catch @panic("oom");
    for (name, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}
