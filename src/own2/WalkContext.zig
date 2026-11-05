//! L8: the module's services a walk reads (`docs/design/ownership-v2.md`
//! §2.6, §2.11.3): what a call runs, the places of an instruction, a local
//! or a code, and the contracts the module has now. `Groups` implements
//! them over a module; `Walk` and `Eval` read them.
//!
//! Obligations kept here: none of §2.14's directly (an interface: `Groups`
//! answers, `Walk` and `Eval` keep the obligations).

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Value = @import("Value.zig");
const Bir = @import("../bir/Bir.zig");

const Error = Ids.ChargeError;
const PlaceId = Ids.PlaceId;

pub const Callee = Contract.Callee;

/// The module's services a walk reads (`Groups` implements them).
pub const Context = struct {
    ctx: *anyopaque,
    placeOfInst: *const fn (ctx: *anyopaque, inst: u32) Error!PlaceId,
    placeOfLocal: *const fn (ctx: *anyopaque, local: u32) Error!PlaceId,
    fieldRank: *const fn (ctx: *anyopaque, s: Bir.SymbolIndex) u32,
    /// A constructor reference's `(ordinal, arity)`.
    ctorOf: *const fn (ctx: *anyopaque, ref: u32) ?[2]u32,
    /// A parameterless value's `(module, declaration)`; `.{ none, 0 }` for a
    /// `foreign`'s, `.{ none, 1 }` for one that holds no object.
    sharedOf: *const fn (ctx: *anyopaque, ref: u32) ?[2]u32,
    isListAppend: *const fn (ctx: *anyopaque, inst: u32) bool,
    callee: *const fn (ctx: *anyopaque, inst: u32, args: []const u32) Error!Callee,
    /// A function reference used as a value (`top`, `ext_value`, a
    /// constructor, a schema member): its code or fixed contract (with
    /// `fixed_bit`), or null when it is not a function.
    funcRef: *const fn (ctx: *anyopaque, inst: u32) Error!?u32,
    /// The codes of the declarations a dispatch site at `inst` passes as evidence (appended, each once).
    evidenceCodes: *const fn (ctx: *anyopaque, inst: u32, out: *std.ArrayList(u32)) Error!void,
    /// The code of a lambda or a local function's `let_def`.
    codeOf: *const fn (ctx: *anyopaque, inst: u32) ?u32,
    /// A code's captures (declaration-relative locals, sorted).
    capturesOf: *const fn (ctx: *anyopaque, code: u32) []const u32,
    /// A code's current contract, or null.
    contractOf: *const fn (ctx: *anyopaque, code: u32) ?Contract.Id,
    /// The called code of body code `code`'s function slot `rel` (§2.11.3), or null.
    calledOf: *const fn (ctx: *anyopaque, code: u32, rel: u32) ?u32,
    /// A code's places: its parameters' (own, then captures) and its result's.
    codeSig: *const fn (ctx: *anyopaque, code: u32) Error!Relation.Sig,
    /// The places of the function type instruction `inst` has at its site:
    /// its parameters' appended, its result's returned; null when it has
    /// no function type.
    siteSig: *const fn (ctx: *anyopaque, inst: u32, params: *std.ArrayList(PlaceId)) Error!?PlaceId,
    /// The same of a label's origin: the function type its callback call's
    /// head has there; null when it has none to hand.
    originSig: *const fn (ctx: *anyopaque, origin: [3]u32, params: *std.ArrayList(PlaceId)) Error!?PlaceId,
    /// The one parameter function slot `(j, rel)` a value of frame `f` is,
    /// read through the contracts settled at the walk (`FnRun.settled`).
    settledParam: *const fn (ctx: *anyopaque, f: *Value.Frame, v: u32) Error!?[2]u32,
    /// The pessimistic contract of a call of `arity` arguments.
    pessimistic: *const fn (ctx: *anyopaque, arity: u32) Error!Contract.Id,
    /// A `try`'s shape: `(success ordinal, failure ordinal, failure arity)` of its
    /// scrutinee's type (`Ok`/`Err` or `Just`/`Nothing`), or null.
    tryShape: *const fn (ctx: *anyopaque, inst: u32) ?[3]u32,
};
