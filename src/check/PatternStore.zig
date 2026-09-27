//! The simplified pattern language `Exhaustive.zig` analyses
//! (docs/design/checker.md §6.6): `anything`, a `literal`, or a `ctor` of a
//! finite union, in one flat store. Split out of `Exhaustive.zig` by R12,
//! which had grown past `checker-v2.md` §19.1's 1 500 lines; `Exhaustive`
//! re-exports every name, so `Exhaustive.PatIndex` and the rest are
//! unchanged for their readers.

const std = @import("std");
const InternPool = @import("../InternPool.zig");
const Types = @import("Types.zig");

pub const Symbol = InternPool.Symbol;

/// Index into `Patterns.nodes`.
pub const PatIndex = enum(u32) {
    _,

    pub fn int(p: PatIndex) u32 {
        return @intFromEnum(p);
    }
};

pub const Tag = enum(u8) {
    /// `_`, a variable, a record pattern: matches everything.
    anything,
    /// One of infinitely many values; `lhs` indexes `literals`.
    literal,
    /// One alternative of a finite union. `lhs` indexes `unions`, `rhs` is
    /// an `extra` offset holding `[alt, arg_count, args…]`.
    ctor,
};

/// One node. Three fixed-size columns and one shared sidecar, like every
/// other IR here.
pub const Node = struct {
    tag: Tag,
    lhs: u32,
    rhs: u32,
};

/// Which surface form a union came from, so the renderer can print `( a, b )`
/// and `x :: xs` rather than the invented constructor names Elm uses.
pub const Shape = enum(u8) { adt, unit, tuple, list };

/// A finite set of alternatives: `alts[alts_start..alts_end]`.
pub const Union = struct {
    shape: Shape,
    /// The declared type, for identity. `.none` only for the invented
    /// unions, which are identified by `shape` and arity instead.
    type: Types.TypeId,
    alts_start: u32,
    alts_end: u32,

    pub fn count(u: Union) u32 {
        return u.alts_end - u.alts_start;
    }
};

pub const Alt = struct {
    /// The constructor's name; `.none` for an invented union's alternative,
    /// which the renderer prints structurally.
    name: Symbol.Optional,
    arity: u32,
};

pub const Literal = struct {
    kind: enum(u8) { int, char, string },
    /// `int`: the value, when the spelling fits. `char`: the scalar.
    value: i128 = 0,
    /// `string`, and an `int` whose spelling did not fit `value`: the bytes
    /// in the module's `string_bytes`, as an offset and a length (never a
    /// slice — `Bir`'s rule, and this store outlives no one).
    off: u32 = 0,
    len: u32 = 0,
    /// False for an `int` whose spelling overflowed `value`: compare the
    /// spelling instead. Two spellings of one number then look different,
    /// which can only ever cost a warning, never invent one.
    parsed: bool = true,

    /// Through `Patterns.bytesOf` and never `string_bytes` directly:
    /// `off`/`len` come from `Bir`, and the invariant that they stay inside
    /// the module's `string_bytes` (`Lower.checkBytes`, fuzz-asserted) is
    /// one held a file away. `bytesOf` re-checks it here, so a spelling
    /// comparison cannot become an out-of-bounds slice if that invariant
    /// ever moves.
    pub fn eql(a: Literal, b: Literal, p: *const Patterns) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .char => a.value == b.value,
            .int => if (a.parsed and b.parsed)
                a.value == b.value
            else
                a.parsed == b.parsed and std.mem.eql(u8, p.bytesOf(a), p.bytesOf(b)),
            .string => std.mem.eql(u8, p.bytesOf(a), p.bytesOf(b)),
        };
    }
};

/// The flat store every simplified pattern lives in. Arena-backed and
/// thrown away with the `case` it was built for.
pub const Patterns = struct {
    nodes: std.MultiArrayList(Node) = .empty,
    /// Constructor argument lists, as `[alt, arg_count, args…]`.
    extra: std.ArrayList(u32) = .empty,
    unions: std.ArrayList(Union) = .empty,
    alts: std.ArrayList(Alt) = .empty,
    literals: std.ArrayList(Literal) = .empty,
    /// The module's decoded literal bytes, which `Literal.off` points into.
    string_bytes: []const u8 = &.{},

    pub fn tag(p: *const Patterns, i: PatIndex) Tag {
        return p.nodes.items(.tag)[i.int()];
    }

    pub fn literal(p: *const Patterns, i: PatIndex) Literal {
        return p.literals.items[p.nodes.items(.lhs)[i.int()]];
    }

    /// The union, absolute alternative index and argument RANGE of a `ctor`
    /// node. A range and not a slice, because `extra` grows as the search
    /// builds counterexamples and a slice taken before one of those
    /// appends would point into a freed block. `args` re-slices at the
    /// moment of use, which is the only time it is valid.
    pub fn ctor(p: *const Patterns, i: PatIndex) Ctor {
        const at = p.nodes.items(.rhs)[i.int()];
        return .{
            .un = p.nodes.items(.lhs)[i.int()],
            .alt = p.extra.items[at],
            .args_start = at + 2,
            .args_len = p.extra.items[at + 1],
        };
    }

    /// The arguments of `c`, valid until the next append to `extra`.
    pub fn args(p: *const Patterns, c: Ctor) []const PatIndex {
        return @ptrCast(p.extra.items[c.args_start..][0..c.args_len]);
    }

    pub fn unionAt(p: *const Patterns, index: u32) Union {
        return p.unions.items[index];
    }

    pub fn alt(p: *const Patterns, index: u32) Alt {
        return p.alts.items[index];
    }

    /// The bytes a literal spells, or empty when its range is not inside
    /// this module's. The bound is widened to `u64` first: `off` and `len`
    /// are both `u32` straight out of `Bir`, and adding them in `u32` is
    /// itself a trap in a safe build — the check may not be the thing that
    /// panics.
    pub fn bytesOf(p: *const Patterns, lit: Literal) []const u8 {
        const end = @as(u64, lit.off) + lit.len;
        if (end > p.string_bytes.len) return "";
        return p.string_bytes[lit.off..][0..lit.len];
    }

    pub const Ctor = struct { un: u32, alt: u32, args_start: u32, args_len: u32 };
};
