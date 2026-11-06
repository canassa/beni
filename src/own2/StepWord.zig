//! L0: a step of a canonical path, one word (`docs/design/ownership-v2.md` §2.1,
//! §3.1), split from `Place`.
//!
//! Obligations kept here: none of §2.14's (a word only).

const std = @import("std");

pub const StepKind = enum(u4) {
    /// `.f`: the payload is the field name's text rank.
    field,
    /// `.i`: a tuple index.
    index,
    /// `C#i`: the payload indexes the table's interned `(constructor,
    /// argument)` pairs; canonical order among them is by the pair.
    ctor_arg,
    /// `[*]`.
    elem,
    /// `◆`.
    contents,
    /// `◇`.
    env,
    /// `⟨n⟩`: an opaque type's published slot.
    slot,
    /// `⟲`: one or more levels below a recursive place. Payload 0.
    level,
    /// `…`: a record's row, the fields its place does not name (§2.1). The
    /// payload indexes the table's interned sets of the names it excludes.
    row,
};

/// A step, one word: `kind` in the top four bits (§3.1).
pub const Step = packed struct(u32) {
    payload: u28,
    kind: StepKind,

    pub const level: Step = .{ .kind = .level, .payload = 0 };
    pub const elem: Step = .{ .kind = .elem, .payload = 0 };
    pub const contents: Step = .{ .kind = .contents, .payload = 0 };
    pub const env: Step = .{ .kind = .env, .payload = 0 };

    /// A payload past 28 bits is the named format limit `step_payload`, never a truncation.
    fn checked(account: anytype, kind: StepKind, payload: u32) !Step {
        try account.limit(.step_payload, @as(u64, payload) + 1);
        return .{ .kind = kind, .payload = @intCast(payload) };
    }

    pub fn field(account: anytype, rank: u32) !Step {
        return checked(account, .field, rank);
    }
    pub fn index(account: anytype, i: u32) !Step {
        return checked(account, .index, i);
    }
    pub fn slot(account: anytype, n: u32) !Step {
        return checked(account, .slot, n);
    }
    /// A `record` value's kid's word: a field's rank, or `row_rank` and a row step's payload.
    pub fn kidWord(s: Step) u32 {
        std.debug.assert(s.kind == .field or s.kind == .row);
        return if (s.kind == .row) row_rank | s.payload else s.payload;
    }
    /// The step of a `record` value's kid's word.
    pub fn ofRank(account: anytype, w: u32) !Step {
        return if (w & row_rank != 0) .{ .kind = .row, .payload = @intCast(w & ~row_rank) } else field(account, w);
    }
    pub fn isRow(s: Step) bool {
        return s.kind == .row;
    }
    /// A step a row may take at a caller: a field's, or a wider row's (§2.1).
    pub fn inRow(s: Step) bool {
        return s.kind == .field or s.kind == .row;
    }
    pub fn word(s: Step) u32 {
        return @bitCast(s);
    }
    pub fn fromWord(w: u32) Step {
        return @bitCast(w);
    }
    pub fn eql(a: Step, b: Step) bool {
        return a.word() == b.word();
    }
};

/// `Step.rank`'s mark of a row's kid: past every field rank (28 bits), so it sorts last.
pub const row_rank: u32 = 1 << 31;
