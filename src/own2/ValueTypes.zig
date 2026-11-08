//! L5: the records of a walk's value tables (`docs/design/ownership-v2.md` §2.3,
//! §3.3), split from `Value`: roots, calls, values and leaves.
//!
//! Obligations kept here: none of §2.14's (records only).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Steps = @import("Steps.zig");

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const SetId = Slots.SetId;
const Pos = Steps.Pos;
const none: u32 = Ids.none_int;

pub const RootKind = enum(u8) {
    /// `a`: the parameter's index (a capture is a parameter after its code's own).
    param,
    /// `a`: the call's index in `Frame.calls`.
    call,
    /// `a`: the label's index in `Frame.cbs`: its answer (§2.11.3).
    cb,
    /// `a`: the index in `Frame.supplies`: what a callee hands one of its labels, described by the callee's supply (§2.11.3).
    supply,
};

/// A call site (§2.11.2): its instruction and point, its arguments (a run
/// of `Frame.kids`, the values; a closure's captures after them), its
/// result root, and the contract read at it (set per evaluation; `none`:
/// the pessimistic one). `virtual`: a label's application to a known code,
/// made by an evaluation (§2.11.3), not by the walk.
pub const Call = struct {
    inst: u32,
    /// The callee's reference instruction (a method call's own), for texts.
    head: u32 = none,
    point: u32,
    args: []const u32,
    /// The arguments' instructions, `none` for a capture or a virtual one.
    arg_insts: []const u32,
    root: u32,
    contract: u32 = none,
    /// The code the call runs when it is one of the module's (`Groups`' numbering), else `none`.
    code: u32 = none,
    /// The callee's value when the call is of a function value.
    callee_val: u32 = none,
    virtual: bool = false,
};

/// A label of the frame (§2.11.3): the function slot `(j, slot)` of a
/// parameter, its origin, its answer's root (a direct call's; `none` for
/// a callee's label the frame passes on), and how it was met.
pub const Cb = struct {
    j: u32,
    slot: u32,
    origin: [3]u32,
    root: u32 = none,
    /// A direct callback call: its instruction, point and argument values.
    inst: u32 = none,
    point: u32 = none,
    args: []const u32 = &.{},
    /// Direct invocations of the label in this frame.
    calls: u8 = 0,
    /// The operand stack's clock at a direct call (the walk's entries).
    pending: u32 = Ids.none_int,
};

/// A supply root (§2.11.3): what call `call`'s callee hands the label
/// virtual call `virtual` applies as argument `k`.
pub const Supply = struct { call: u32, virtual: u32, k: u32, root: u32 };

pub const Root = struct {
    kind: RootKind,
    a: u32,
    place: PlaceId,
    /// The root place's `ε` path: every position's slot is below it.
    path: PathId,
    pos: u32 = none,
};

pub const Kind = enum(u8) {
    scalar,
    bot,
    top,
    built,
    ref,
    alt,
    shared,
    /// A parameterless `foreign`'s value (§2.10, *host objects*).
    host,
};

/// What a `built` value is (§2.3.3).
pub const Form = enum(u8) {
    tuple,
    /// (`list`: `head` is 0, or one more than the value whose storage the
    /// list is: a construction over its base, §2.13.2.)
    /// `head`: the constructor's ordinal in its type.
    ctor,
    list,
    /// `extra`: the run of the fields' ranks in `words`, in the kids' order.
    record,
    /// `head`: the code (`Groups` numbers codes); kids are the captures.
    closure,
    /// A markup tree or another opaque object: its kids are what it holds.
    opaque_,
};

/// One value (§2.3.3). `built`: `form`, `head`, `site` (the instruction whose
/// object is its storage, or `none`), `extra`. `ref`: `root`, `pos` and
/// `family` (a slot set, or `Slots.empty` for the position's own subtree).
/// `alt`: `head` the choice; kids are `(arm, value)` pairs. `shared`:
/// `head` the module, `site` the declaration. `top`: `site` its origin (a `top` leaf's `root`, §2.3.4).
pub const Val = struct {
    kind: Kind,
    /// The value's place, `.none` when unknown: a `⟲` projection of a
    /// built value follows the parts that stay on the place's cycle.
    place: PlaceId = .none,
    form: Form = .tuple,
    head: u32 = 0,
    site: u32 = none,
    extra: []const u32 = &.{},
    root: u32 = none,
    pos: u32 = none,
    family: SetId = Slots.empty,
    kids: []const u32 = &.{},
};

pub const LeafKind = enum(u8) {
    /// The objects at `slots` in the subtree at `pos` of `root`.
    ref,
    /// The object built by instruction `atom`.
    site,
    /// The objects call `atom`'s callee allocated.
    fresh,
    /// A top-level value: `atom` the module, `extra` the declaration.
    shared,
    /// The answer of a label the frame cannot apply (§2.11.3): `atom` its `cbs` index, `extra` the answer's slot (a `Slots.Rel`).
    answer,
    top,
    /// A loan of what a cell holds (§2.13.7): `atom` the leaf it lends.
    /// A holder of it holds what that leaf names; written, it is unknown.
    loan,
    /// A prepend's deferred storage, `atom` its value (§2.3.4; a leaf set's).
    recons,
    /// Objects JavaScript made, or beni objects that escaped (§2.10, *host objects*).
    host,
};

pub const Leaf = struct {
    kind: LeafKind,
    atom: u32 = 0,
    extra: u32 = 0,
    root: u32 = none,
    pos: u32 = none,
    slots: SetId = Slots.empty,
    /// A tag set (`Frame.tags`), 0 for none; a route set a projection
    /// reached it under, relative to `tags` (§2.11.2), 0 for none.
    tags: u32 = 0,
    routes: u32 = 0,
    /// A shallow target at its position's own slot only.
    at_pos: bool = false,
    /// An answer read whole, its slot and all below it (§2.1, *An arrival's level*).
    whole: bool = false,
};
