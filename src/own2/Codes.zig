//! L12: what a module's check keeps per code and per declaration
//! (`docs/design/ownership-v2.md` §2.10, §2.12): a code (a body, a lambda,
//! a local function, a reference) with its contract and walk, and one
//! declaration's answer (its contract, rounds, walks and judged lines).
//! `Groups` numbers the codes and solves the groups.
//!
//! Obligations kept here: none of §2.14's directly (records: `Groups`
//! fills them).

const Ids = @import("Ids.zig");
const Walk = @import("Walk.zig");
const Kept = @import("Kept.zig");

const PlaceId = Ids.PlaceId;
const none = Ids.none_int;

/// One declaration's answer.
pub const DeclResult = struct {
    decl: u32,
    /// Its body code's final contract, or `none` (a limit stopped it).
    contract: u32 = none,
    /// Rounds of evaluations its group took (§2.12): 2 when nothing moved after the first.
    rounds: u32 = 0,
    /// Walks of its codes: one each.
    walks: u32 = 0,
    /// Validations that found a code outside its candidate (§2.12 step 3).
    defects: u32 = 0,
    lines: []Kept.Line = &.{},
    /// The account's failure, when it stopped the walk.
    failure: ?Ids.Failure = null,
    account: Ids.Account = .{},
};

pub const CodeKind = enum(u8) { body, lambda, local, ref, called };

/// A code (§2.10).
pub const Code = struct {
    kind: CodeKind,
    /// The declaration it is in (a body, a lambda, a local function, a called code).
    decl: u32 = none,
    /// A called code (§2.11.3): its body's code and the function slot.
    of: u32 = none,
    slot: u32 = 0,
    /// The lambda's or `let_def`'s instruction; a reference's instruction.
    inst: u32 = none,
    params: Ids.Range = .{},
    own: u32 = 0,
    result: PlaceId = .none,
    captures: Ids.Range = .{},
    contract: u32 = none,
    /// Moves when the contract does (§2.12's read check).
    version: u32 = 0,
    walk: ?*Walk.Walk = null,
};
