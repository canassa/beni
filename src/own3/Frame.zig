//! own3, layer 3: one walk of one code (`docs/design/ownership-v3-kernel.md`,
//! the normative text; research report 110 §6.3, §6.7; report 111 §2). A
//! code is a declaration's body, a lambda or a local function. The walk goes
//! over the expression tree once, in evaluation order, and gives each
//! expression a **value** (kernel §3):
//!
//! - `none`: no object, by the type;
//! - `outside`: an object whose every cell is outside this frame — a
//!   top-level value, or a function that captured nothing (a constructor, a
//!   function in the default state). It holds no cell of the frame, and the
//!   reason is in the kind: the position rule;
//! - `ref(root, path)`: a part of a root of this frame;
//! - `built`: a tuple, a record or a constructor application of this frame.
//!   It names every part that holds a cell; a part it does not name holds
//!   none;
//! - `join`: the value of one of several branches;
//! - `closure`, `fnref`: a function value whose code is known;
//! - `unknown(V)`: a value that the walk cannot follow: no claim, and it can
//!   hold every cell of each value of `V`, at every location;
//! - `later`: in a closure, a local of this frame that is bound after the
//!   closure is made (`capVal` reads it, and nothing else does).
//!
//! There is no value that means "I do not know what this holds" and reads as
//! "holds nothing": a value the walk cannot follow is `unknown` over what it
//! was made of, and a walk that cannot go on gives up (`giveUp`), so its
//! declaration publishes no contract and accepts no write.
//!
//! A **root** is a parameter, a captured local, a value that the frame made
//! (a list literal, a call's result), a cell that a callee made (`fresh`,
//! named by the call and the callee's allocation site: kernel §4.2), or the
//! answer of a function parameter. An **atom** `(root, path, entry)` names
//! the cells of one location of a root at or below a path. Two atoms can be
//! one cell only when they have one root and one entry, and one path is a
//! prefix of the other.
//!
//! **A write makes a new name.** Where a callee writes a location and
//! answers it, the result's location is a new atom (`version`), not the old
//! one. So each reference made before the write names the old cells, and
//! "nothing reads the old value later" is one test: no read after the write
//! reaches a target atom.
//!
//! **A read is at a consumer.** A call reads its argument at the locations
//! its contract flags; an unknown callee reads all of it. A list pattern
//! reads its list. The frame's result is read where it is answered. A
//! binding, a field access and a construction read nothing: they only make
//! another holder.
//!
//! **The write rule** (kernel §5). A write is accepted when no target atom is
//! outside, a capture or a function parameter's answer, no value that escaped
//! before the write reaches a target, no other operand that the operation
//! reads reaches a target, and no read after the write reaches a target.
//!
//! **Function values** (research report 112 §2). A function value is known
//! (the frame has its code, or it is the frame's own function parameter) or
//! it is in the default state. Each consumer of a known function is a use,
//! and one operation, `flow`, judges the function against the use. A
//! consumer that no contract describes is the `top` use: it refuses a
//! function that writes its parameter. So a forgotten case gives `top`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Ids = @import("../own2/Ids.zig");
const Place = @import("../own2/Place.zig");
const Facts = @import("../own2/Facts.zig");
const Loc = @import("Loc.zig");
const CMod = @import("Contract.zig");
const Check = @import("Check.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Edges = @import("../check/Edges.zig");
const InternPool = @import("../InternPool.zig");
const OwnHoists = @import("Reads.zig");

const Contract = CMod.Contract;
const Mod = Check.Mod;
const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Inst = Bir.Inst;
const Var = TypeStore.Var;
const Src = CMod.Src;
const none = Loc.none;
const flag_w = CMod.flag_w;
const flag_e = CMod.flag_e;
const flag_r = CMod.flag_r;
const flag_s = CMod.flag_s;
const flag_a = CMod.flag_a;

pub const Val = u32;
pub const v_none: Val = 0;
pub const v_outside: Val = 1;
/// The value of a local before its binding runs. Nothing reads it: a local
/// is read through `evalInner` only where its frame bound it (kernel §3.3).
pub const v_unbound: Val = std.math.maxInt(u32);

const Tag = enum(u8) { none, outside, ref, built, join, closure, fnref, unknown, later };
/// `pos` of a `ref`: the match and position every atom of it is read at
/// (`Atom.pos`), or `none`.
const Node = struct { tag: Tag, place: PlaceId = @fromBackingInt(0), a: u32 = 0, b: u32 = 0, pos: u32 = none };
const Kid = struct { step: u32, val: Val };
/// `via`: the root that the frame made through which this cell was read
/// (a call's result that holds cells of its arguments), or `none`.
///
/// `dead`: an old name of cells that have a new name since the time `dead`
/// (`timeOf`: a callee wrote them, or could, and answers them), or `none`.
/// The value that holds the new name is no reader of the old value: a write
/// at that time or before does not count it as a holder. The cells are the
/// same: a write after that time counts it, and so does an overlap test for
/// one cell at two places.
/// `via_path`, `via_e`: the part of `via` that was read (its path and entry), so
/// that two reads of one part of a linear root are one cell and two reads of
/// two parts of it are two (`viaApart`).
/// `pos`: the match of a list pattern and the position in it that the cell
/// was read at (`listParts`, kernel §4.4, *The parts of a list pattern are
/// apart*), or `none`: two atoms of one match at two positions are two cells.
/// `via2`, `via2_e`: the last root the frame made through which the cell was
/// read, and the entry of it (`copyAtoms`); `via` is the first. A root that
/// holds each cell once tells two of its entries apart whichever root an atom
/// was first read through (`viaApart`; kernel §4.4, *Two readings through a
/// later root*).
/// `ren`: a copy of a cell's contents that the frame took at a switch point
/// (kernel §13 item 12), at that time, or `none`: for a probe at that time
/// or before it, the holder is no holder of a value taken before the switch.
/// Read only while a probe is judged (`isOld`); a write reads `dead` alone.
pub const Atom = struct { root: u32, path: u32, e: u32, via: u32 = none, via_path: u32 = none, via_e: u32 = none, dead: u32 = none, pos: u32 = none, via2: u32 = none, via2_e: u32 = none, ren: u32 = none };
/// `outside`: root 0, the one root of every cell outside the frame (kernel
/// §3.1). `fresh`: a cell a callee made, named by the call and the callee's
/// allocation site (kernel §4.2); it has no layout and no value, only atoms.
const RootKind = enum(u8) { outside, param, capture, local, answer, fresh };
/// Whether no cell of another root is at two places of a root the frame
/// made. It is `undecided` until `deriveLinear` ran over the root's entries,
/// and a reader that meets `undecided` reads it as `no` (kernel §4.4,
/// *linear is derived, never assumed*; a safe build asserts it never does).
const Linear = enum(u8) { undecided, no, yes };
const Root = struct {
    kind: RootKind,
    place: PlaceId = @fromBackingInt(0),
    layout: u32 = 0,
    inst: u32 = none,
    /// `param`, `capture`: the contract's parameter. `answer`: the function draft.
    index: u32 = none,
    /// `local`: its entries. `param`, `capture`: its flags in `pflags`.
    ent: u32 = 0,
    /// `local`, `fresh`: a call's result (the ground of a verdict).
    call: bool = false,
    linear: Linear = .undecided,
    path: u32 = 0,
    /// `fresh`: the cell's name in this frame's contract (`freshId`), and
    /// whether its escape in the callee was noted here (`freshAtom`).
    site: u64 = 0,
    escaped: bool = false,
    /// Kernel §13: a root whose cells' contents the frame follows — a
    /// parameter, a call's answer that holds new cells' handles and no
    /// other, a version of one. A `local` root that is no such root holds
    /// `outside` too below each handle (`rootLeaves`).
    tracked: bool = false,
    /// A version of a tracked root (`renewHandle`): the root it renews.
    origin: u32 = none,
    /// Its layout has a cell's handle (`innerOf`).
    cells: bool = false,
    /// A tracked root that a call renewed: the value of its latest version,
    /// a `ref` of a version root or a `join` of them; else `none`.
    latest: Val = none,
    /// `fresh`: the new cell's handle that a tracked root holds, that root
    /// and the entry (`cellResult`); else `none`.
    cell_root: u32 = none,
    cell_e: u32 = 0,
    /// A version that renames a tracked root's contents at a switch point
    /// (`renameContents`): the value it was made from; else `none`.
    rename_of: Val = none,
};
/// What a location of a root that the frame made holds. Each kind is a run
/// of atoms (`start`, `len`), and some have an **own atom** `(root, path,
/// entry)` beside it: `own`, a cell the frame made and nothing else;
/// `alias`, the cells of the run and no other (a call's result: its fresh
/// cells are `fresh` roots in the run); `derived`, an own cell or the run's
/// (a prepend that may answer the array of its base); `version`, the new
/// name of cells that a callee wrote and answers (the old names are in the
/// run, `dead`: a write of the new name is a write of them); `taken`, an
/// element that a trusted loop of `core/` took out of its list.
const EKind = enum(u8) { own, alias, derived, taken, version };
/// `twice`: the location is a summary location that can hold one of its
/// cells at two of its places (kernel §4.4). It keeps its claim, but its
/// parts are not apart: a part of it is all of it, and a callee that writes
/// it is refused (`leavesOwn` says so).
const REntry = struct {
    kind: EKind,
    start: u32 = 0,
    len: u32 = 0,
    twice: bool = false,

    fn hasOwn(e: REntry) bool {
        return switch (e.kind) {
            .own, .derived, .taken, .version => true,
            .alias => false,
        };
    }
};
/// `point`: the consumer's instruction, for the text. `at`: the time of the read (`timeOf`).
/// `tail`: the frame's answer, read where it is answered. A field slot of a
/// parameter it reaches is answered in the contract (`flag_a`), not read: the
/// caller holds the answer and reads its slots where it reads them, and a
/// call that writes counts it as another operand (kernel §5, §11).
const Read = struct { point: u32, at: u32, val: Val, ctx: u32, mask: u32 = 0, nmask: u32 = 0, all: bool = true, tail: bool = false };
const Escape = struct { start: u32, len: u32, point: u32, ctx: u32 };
const Ctx = struct { parent: u32, case: u32, arm: u32, depth: u32 };
/// A call or a method call as the walk applied it (`noteJsSite`): the
/// instructions its edges are at (the callee's reference and the call, or
/// `none`), what it was handed (`vals`, a run of `js_site_vals`), what it
/// answered, and whether it made the frame cast.
const JsSite = struct { pos: [2]u32, vals: u32, nvals: u32, result: Val, casts: bool };

/// A function value whose code the frame knows.
const Code = struct {
    contract: *const Contract,
    /// The captured values, a run of `lists`, after the code's own parameters.
    caps: u32 = 0,
    ncaps: u32 = 0,
    /// The lambda, the local function, or `none` for a named declaration.
    inst: u32 = none,
    decl: [2]u32 = .{ none, none },
    own_params: u32,

    /// The code's name among the holders of one frame: a lambda or a local
    /// function by its instruction, a declaration by its module and index.
    /// The same in every round of a group (`freshAtom`).
    fn id(c: Code) u64 {
        return if (c.inst != none) std.hash.Wyhash.hash(1, std.mem.asBytes(&c.inst)) else std.hash.Wyhash.hash(2, std.mem.asBytes(&c.decl));
    }
};

/// What the frame hands one function parameter, while it is walked.
const FnDraft = struct {
    root: u32,
    arity: u32,
    places: []const PlaceId,
    layouts: []const u32,
    off: []const u32,
    supply: []std.ArrayList(Src),
    free: []bool,
    called: bool = false,
    lost: bool = false,
    ans_escapes: bool = false,
    rewrites: bool = false,
    /// The body does something with the function: it calls it or lets it flow.
    used: bool = false,
};

/// The call or the mention at which a function value flows: where a demand
/// and a refusal are, and the operands that a demand is judged against.
const Site = struct {
    inst: u32,
    callee: u32 = none,
    arg_insts: []const Inst.Index = &.{},
    others: []const Other = &.{},
};

/// What the holder of a function-typed location does with a function there
/// (research report 112 §2). Each consumer of a function value is one of
/// three uses, and `flow` is the one rule that judges a value against a use.
///
/// - `call`: the location is parameter `j` of the callee `c` of the call in
///   work. `args` are the values of the callee's parameters, and `fnc` says
///   what the callee hands the function.
/// - `inner`: the location is capture `j` of a known function whose contract
///   is `c`, and `up` is the use of that function. `args[own..]` are the
///   captured values. What the first `own` parameters are is what `up` hands
///   them. This is the composition of two contracts, at any depth.
/// - `top`: no contract describes the holder (the default). It runs the
///   function at any time, any number of times, with values that are not the
///   function's own, and it keeps the answer.
const Use = struct {
    kind: enum(u8) { call, inner, top },
    /// One number for each holder of a walk (a call, a known function, the
    /// default). With `j` it names the location: an answer or a supply in
    /// work is known by the two.
    id: u32 = 0,
    /// The name of the location among the locations of one call: the call's
    /// instruction for the call itself, and for a captured function the
    /// holder's key and the capture's index (`innerUse`). With `holder`, the
    /// code whose contract `c` is (`Code.id`), a `fresh` cell read at this use
    /// is one root by `(key, holder, k)` (`freshAtom`), so every reader of one
    /// call names one cell once, and two codes read at one call never share a name.
    key: u64 = 0,
    holder: u64 = 0,
    c: *const Contract = undefined,
    fnc: *const CMod.Fn = undefined,
    j: u32 = none,
    args: []const Val = &.{},
    own: u32 = 0,
    up: ?*const Use = null,
    /// Whether a holder above this one writes a cell after it handed that
    /// cell on (`rewritesOf`): set where the use is made, so a judgment
    /// reads it as a fact of its own use.
    up_rewrites: bool = false,
    site: *const Site,
    depth: u32 = 0,
    /// The function in the location, once `flow` knows which it is: a known
    /// function, or the frame's own function parameter at `root`.
    code: ?Code = null,
    root: u32 = none,
};

/// What a use hands one parameter location of the function. `fe` is `none`
/// when the use's type has no entry for it: `srcs` then says all (the
/// default hands a value with no claim; a type with no object there hands no cell).
const Slot = struct { fe: u32, free: bool, srcs: []const Src };

/// The atoms `f.atoms[start..]` that a source of a use is in this frame.
const Handed = struct {
    start: u32,
    dup: bool,
    /// The level whose parameter the atoms are of, the parameter and its entry.
    use: *const Use,
    a: u32,
    e: u32,
    suffix: []const u64,
    /// A value that a known function captured: each run hands the same cells.
    captured: bool,
};

/// The parameter locations whose supply is in work, and the answers that
/// must be `own`: `(holder, location, parameter or none, entry)`.
const Seen = struct {
    n: u32 = 0,
    keys: [32][4]u32 = undefined,
    fn visit(s: *Seen, use: *const Use, k: u32, e: u32) enum { new, old, full } {
        const key: [4]u32 = .{ use.id, use.j, k, e };
        for (s.keys[0..s.n]) |x| if (std.mem.eql(u32, &x, &key)) return .old;
        if (s.n == s.keys.len) return .full;
        s.keys[s.n] = key;
        s.n += 1;
        return .new;
    }
};

/// The answer of one call of a function parameter: a root, and what the
/// function was handed there (its answer can hold it).
const Answer = struct { di: u32, inst: u32, root: u32, base: std.ArrayList(Atom) = .empty };

const Op = enum(u8) { call, construction, append, supply, update };

/// Another operand of the operation that writes: what the operation reads of it.
const Other = struct {
    v: Val,
    /// The signature layout its flags are over, or `none`: all of it is read.
    sig: u32 = none,
    flags: []const u8 = &.{},
    /// A spread item: its own storage is read.
    self_only: bool = false,
};

const Demand = struct {
    point: u32,
    /// The time of the write (`timeOf`).
    at: u32,
    token: u32,
    ctx: u32,
    op: Op,
    kind: Facts.DemandKind,
    w: u32,
    wn: u32,
    callee_inst: u32 = none,
    base_inst: u32 = none,
    /// The written location, below the base, for the text.
    loc: u32 = 0,
    refused: ?Facts.Cause = null,
    detail: []const u8 = "",
    /// `supply`: the function draft and the slot the check is for.
    draft: u32 = none,
    slot: u32 = 0,
    /// `supply`: the answer of the same call, which is not a read of the old value.
    skip: u32 = none,
    /// A write of a record's field slot (kernel §11): its diagnostic is a record's.
    record: bool = false,
    /// `supply`: the function is the runtime's `send`: the check has a line.
    send: bool = false,
    /// `update`: the later reads of a written slot that the lowering reads
    /// before the stores (kernel §11, *A read of a written field, read first*).
    hoists: []const OwnHoists.Read = &.{},
};

m: *Mod,
gpa: Allocator,
parent: ?*@This(),
id: u32,
decl: u32,
d: Bir.Decl,
is_lambda: bool,
code_inst: u32,
/// The body the frame walks (`walkBody`), for the hoist test (`hoistRow`).
body_root: u32 = none,
/// The parent of each instruction of the body, made when a hoist is first asked for.
parents: []u32 = &.{},
parents_made: bool = false,
own_params: u32 = 0,
depth: u32 = 0,
failed: bool = false,
/// An answer of the body can be an object that was there before (`Contract.old_result`).
tail_old: bool = false,
/// The body read a value at a type variable that is not its own type (`narrowed`), or used the answer of a callee that did (`Contract.casts`).
casts: bool = false,

nodes: std.ArrayList(Node) = .empty,
kids: std.ArrayList(Kid) = .empty,
lists: std.ArrayList(u32) = .empty,
roots: std.ArrayList(Root) = .empty,
rents: std.ArrayList(REntry) = .empty,
atoms: std.ArrayList(Atom) = .empty,
pflags: std.ArrayList(u8) = .empty,
/// The contract's parameters: the roots, own parameters first, then captures.
params: std.ArrayList(u32) = .empty,
/// Per parameter of the contract: its type, for a function parameter's draft.
param_ty: std.ArrayList(Var.Optional) = .empty,
/// The captured locals, in the order of `params` after the own parameters.
cap_locals: std.ArrayList(u32) = .empty,
codes: std.ArrayList(Code) = .empty,
drafts: std.ArrayList(FnDraft) = .empty,
answers: std.ArrayList(Answer) = .empty,
/// While a supply is judged: the answer root that does not count as a holder.
skip_answer: u32 = none,
/// While a write is judged: its context. The value of another arm of the same `case` is not a holder.
judge_ctx: u32 = none,
/// While a write is judged: its time (`isOld`).
judge_at: u32 = none,
/// Set by `argLeaves` when the fallback cover gave an entry.
hit_all: bool = false,
/// Set by `argEntries` when a part that `pairedLeaves` asks for is no
/// location of the argument's own layout, and every entry is read.
suffix_fallback: bool = false,
/// Set by `argEntries` when a wide entry of the argument read at a summary
/// location below it gave an entry (`Loc.holes`): no single place.
coarse_hit: bool = false,
/// Set by `argEntries` when the location asked for is a record's field slot
/// that the argument's own layout has no slot for (`slotsLost`).
slot_lost: bool = false,
uses: std.ArrayList(Read) = .empty,
escapes: std.ArrayList(Escape) = .empty,
/// The atoms of each escape, a run per `Escape`: a copy, so a run of `atoms` under construction can be compacted after it noted one.
esc_atoms: std.ArrayList(Atom) = .empty,
demands: std.ArrayList(Demand) = .empty,
ctxs: std.ArrayList(Ctx) = .empty,
cur_ctx: u32 = 0,
returns: std.ArrayList(Val) = .empty,
scratch: std.ArrayList(Atom) = .empty,
/// While a spread literal or a `++` chain is walked: its root call.
chain_root: u32 = none,
/// The next `Use.id`.
next_use: u32 = 1,
/// The judgments of `flow` that the walk in work made, by what each read
/// (`FlowKey`), and the ones in work. Kept while one walk of `flow` runs.
flow_memo: std.AutoHashMapUnmanaged(FlowKey, [2]u32) = .empty,
flow_args: std.ArrayList(Val) = .empty,
/// The values that the walk of values in work found (`leafHit`), and the values that `reach` in work reached.
leaf_memo: std.AutoHashMapUnmanaged(LeafKey, LeafHit) = .empty,
leaf_buf: std.ArrayList(Atom) = .empty,
leaf_ks: std.ArrayList(u32) = .empty,
leaf_nest: u32 = 0,
reach_seen: std.AutoHashMapUnmanaged(Val, void) = .empty,
/// The part of each join that `project` made, by the join and the step:
/// kept for the frame, since a value never changes once it is made.
proj_memo: std.AutoHashMapUnmanaged([2]u32, Val) = .empty,
/// Per construction (a `built` value): for each entry of its place's
/// layout, the parts that hold a location there (`builtIndex`).
built_index: std.AutoHashMapUnmanaged(Val, BuiltIndex) = .empty,
/// Per construction of more than `scan_parts` parts, each part by the
/// construction and its step (`project`), and the constructions so indexed.
built_parts: std.AutoHashMapUnmanaged([2]u32, Val) = .empty,
built_parted: std.AutoHashMapUnmanaged(Val, bool) = .empty,
/// Per own cell `(root, path, entry)` that `freshSrc` asked about: how many
/// escapes it has tested, whether one of them holds the cell, and the atoms
/// of those escapes. Escapes only grow, so the answer for the escapes tested
/// stands (kernel §8).
fresh_esc: std.AutoHashMapUnmanaged([3]u32, [3]u32) = .empty,
/// The matches of the positions of a `get` and a `set` (`posKey`, kernel §6
/// rule 10, *A position*): by the list (its root, path and position) and the
/// index local, and each match with its key, in the order made (`posSrc`
/// scans them: a frame makes few).
pos_keys: std.AutoHashMapUnmanaged([4]u32, u32) = .empty,
pos_info: std.ArrayList([5]u32) = .empty,
/// Per layout, its index for `slotHeld` once made (`slotIndex`), or null.
slot_index: std.ArrayList(?*const SlotIndex) = .empty,
/// The result of the call in work (`applyAt`), or 0, and the next one: what
/// `argLeavesKept` keeps, by the call, the argument and the entry.
paired_gen: u32 = 0,
next_paired_gen: u32 = 1,
paired_memo: std.AutoHashMapUnmanaged([4]u32, PairedHit) = .empty,
paired_buf: std.ArrayList(Atom) = .empty,
/// The walk is over (`finish`): a value of no claim, or a closure, has the
/// atoms that its first walk found, kept by the value (`whole_at`: where they
/// start in `whole_buf`, and how many), so that `finish`, which reads the
/// result once for each of its locations, walks each such value once.
finished: bool = false,
whole_at: std.ArrayList([2]u32) = .empty,
whole_buf: std.ArrayList(Atom) = .empty,
/// The atoms of the write in judgement, grouped by root and entry, when
/// there are more than `w_index_min` of them (`indexWrite`).
w_ix: WIndex = .{},
/// Per root the frame made, the entries whose runs `rootReach` reads, once
/// its entries are made (`runEntries`).
run_ents: std.ArrayList(?RunEntries) = .empty,
reach_nest: u32 = 0,
flow_active: std.ArrayList(struct { key: FlowKey, args: []const Val }) = .empty,
/// The lowest depth of a use whose context the judgments in work read: the
/// use above it, or its key (`upOf`, `freshAtom`).
ctx_floor: u32 = std.math.maxInt(u32),
/// The `fresh` roots of this frame, by the holder's key, the contract the
/// source was read from and its allocation site (`freshAtom`).
fresh_roots: std.AutoHashMapUnmanaged(FreshKey, u32) = .empty,
/// The last call whose arguments `call` evaluated, and their values.
call_inst: u32 = none,
call_vals: []const Val = &.{},
/// Each call and method call of this frame, with what it was handed and
/// answered (`noteJsSite`), judged when the frame's answer is known
/// (`judgeJsSites`): which of their edges can see a cell of the contract
/// (kernel §6 rule 10, *An edge counts only where what it can see reaches
/// the contract*). Kept only where the module's bodies are read for
/// JavaScript (`Mod.js_seen`).
js_sites: std.ArrayList(JsSite) = .empty,
js_site_vals: std.ArrayList(Val) = .empty,
/// The walk's clock (`timeOf`): the time of the last operation, its
/// instruction, and the count of expressions entered when it was taken.
clock: u32 = 0,
clock_inst: u32 = none,
clock_entered: u32 = 0,
/// The count of expressions that the walk entered (`eval`).
entered: u32 = 0,
/// While the holes of markup are walked: every value of a local that they
/// read, which the markup holds (`evalInner .markup`).
markup_reads: ?*std.ArrayList(Val) = null,
/// Per entry of `rents`, what the walks of its run know of it (`RunFact`),
/// grown to `rents` where it is read (`runFact`).
run_facts: std.ArrayList(RunFact) = .empty,
/// The visit of runs in progress (`newVisit`): an entry whose `RunFact.seen`
/// is this one was visited by it.
visit: u32 = 0,
/// The work list of `markAtom`, `groundOf` and `atomSrcs`: a run is walked
/// with no recursion, so a chain as long as the budget allows needs no stack.
mark_stack: std.ArrayList(Atom) = .empty,
/// Per pair of layouts: which entries of the second meet each entry of the
/// first (`meetsOf`), built once from the two call maps.
meet_index: std.AutoHashMapUnmanaged([2]u32, *const MeetIndex) = .empty,
/// Per pair of layouts: the call map read the other way (`coverHits`).
cover_index: std.AutoHashMapUnmanaged([2]u32, *const CoverIndex) = .empty,
/// Kernel §13. The tracked roots that a call renewed (`Root.latest`), each once.
cell_roots: std.ArrayList(u32) = .empty,
/// The handles with another holder, by the tracked root and its entry.
cell_shared: std.AutoHashMapUnmanaged([2]u32, void) = .empty,
/// Per layout, by its number: for each entry, whether it is in a cell's
/// contents (`innerOf`), once made.
cell_inner: std.ArrayList(?[]const bool) = .empty,
/// At each return point (each `?`, and the end of the walk): each tracked
/// parameter's value there, `(root, value)`, and the read of its cells'
/// contents there, which `cellReads` keeps where the parameter is renewed.
ret_cells: std.ArrayList([2]u32) = .empty,
ret_reads: std.ArrayList(Read) = .empty,
/// The shares that `shareAtoms` noted, `(root, entry, point)`, made by `flushShare`.
share_pending: std.ArrayList([3]u32) = .empty,
/// The frame follows some cell's contents: else no hook of kernel §13 does work.
cells_any: bool = false,
/// Kernel §13 item 12. The body made a call where another fiber can run
/// (`switchAt`): the contract's `switches`.
switched: bool = false,
/// While a probe is judged: `isOld` reads `Atom.ren` too.
judge_probe: bool = false,
/// The handles of tracked roots the frame made that a holder marked
/// (`Contract.flag_m`): no function that writes their contents runs in
/// another fiber (`revokeWriters`).
cell_marked: std.AutoHashMapUnmanaged([2]u32, void) = .empty,
/// At each switch point, each tracked parameter's or capture's contents.
probes: std.ArrayList(Probe) = .empty,
/// The functions that write the contents of a cell the frame made and run
/// where the walk does not follow them, a spawned fiber's among them.
writers: std.ArrayList(Writer) = .empty,

const Frame = @This();
pub const Error = Allocator.Error;
const safety = std.debug.runtime_safety;

const FreshKey = struct { key: u64, holder: u64, k: u32 };
/// A probe (kernel §13 item 12): the contents `atoms[w..][0..wn]` of the
/// handle at entry `h` of tracked parameter or capture `root` at the switch
/// point at time `at`; refused where a value taken out of them before is
/// read after, or the call reads one (`refused`, set at the call).
const Probe = struct { w: u32, wn: u32, at: u32, ctx: u32, root: u32, h: u32, refused: bool };
/// A function that writes the contents of capture `k` of the known code
/// `code` (an index of `codes`), the handle at entry `e` of root `o` that
/// the frame made, and goes where the walk does not follow it at `site`.
const Writer = struct { code: u32, k: u32, o: u32, e: u32, site: u32 };
const PairedHit = struct { start: u32, len: u32, dup: bool, hit_all: bool };

pub fn init(m: *Mod, parent: ?*Frame, decl: u32, is_lambda: bool, code_inst: u32) Error!Frame {
    var f: Frame = .{ .m = m, .gpa = m.walk_arena.allocator(), .parent = parent, .id = m.next_frame, .decl = decl, .d = m.bir.decls[decl], .is_lambda = is_lambda, .code_inst = code_inst };
    m.next_frame += 1;
    f.depth = if (parent) |p| p.depth + 1 else 0;
    try f.nodes.append(f.gpa, .{ .tag = .none });
    try f.nodes.append(f.gpa, .{ .tag = .outside });
    try f.roots.append(f.gpa, .{ .kind = .outside, .linear = .yes });
    try f.ctxs.append(f.gpa, .{ .parent = none, .case = none, .arm = 0, .depth = 0 });
    return f;
}

/// The walk cannot go on (a value read before it is bound, code with no
/// contract to read): the declaration publishes no contract and accepts no
/// write (`finish`, `Check.walkDecl`). The value stands for the expression
/// at `inst` while the walk completes, so that every later line of this
/// frame is still made and refused.
/// One step of a walk that can come back to what it walked (kernel §8):
/// true once the declaration passed `Check.max_walk_steps`, or the module
/// its budget (`Check.Mod.overBudget`). Past it every walk returns at once,
/// and the declaration gives up.
fn tick(f: *Frame) bool {
    const m = f.m;
    if (m.steps_over) return true;
    m.steps += Check.call_units;
    m.module_units +|= Check.call_units;
    if (m.overBudget()) {
        m.steps_over = true;
        f.failed = true;
    }
    return m.steps_over;
}

/// `n` units of work of a loop over atoms, counted against the
/// declaration's budget and the module's (kernel §8): a step's own cost grows with the atoms
/// it compares, so the budget counts them. True once the declaration is past
/// it; the caller then answers on the pessimistic side.
fn charge(f: *const Frame, n: u64) bool {
    const m = f.m;
    if (m.steps_over) return true;
    m.steps +|= n;
    m.module_units +|= n;
    if (m.overBudget()) m.steps_over = true;
    return m.steps_over;
}

fn giveUp(f: *Frame, inst: u32) Error!Val {
    f.failed = true;
    return f.unknownOf(try f.m.placeOfInst(inst), &.{});
}

pub fn addParam(f: *Frame, place: PlaceId, pat: u32, ty: Var.Optional) Error!void {
    const root = try f.newRoot(.param, place, pat);
    f.roots.items[root].index = @intCast(f.params.items.len);
    // The caller's hand (kernel §13): the frame follows a parameter's cells.
    if (f.roots.items[root].cells) {
        f.roots.items[root].tracked = true;
        f.cells_any = true;
    }
    try f.params.append(f.gpa, root);
    try f.param_ty.append(f.gpa, ty);
    try f.bindPattern(pat, try f.rootVal(root));
}

pub fn walkBody(f: *Frame, body: u32) Error!void {
    f.body_root = body;
    // The answer is read at the end of the walk: a tracked root at its last version (kernel §13).
    const v = try f.cellsNow(try f.eval(body, .value, true));
    try f.writersAtReturn(body, v);
    try f.noteReturnCells(body);
    try f.returns.append(f.gpa, v);
}

/// A value that the program hands to code of the compiler's own, which keeps
/// it for as long as the program runs and calls each function in it at any
/// time, any number of times, with values that have no claim: a `schema`
/// declaration's `via` conversion, which its compiled workers and its
/// `S.schema` value hold (kernel §6.14). The expression is walked as any
/// other; its value is in a location with the default contract, so a
/// function in it goes to the `top` use (`mention`, rule 8), and every cell
/// it holds escapes.
pub fn walkHeld(f: *Frame, root: u32) Error!void {
    const v = try f.eval(root, .value, false);
    try f.escape(v, root);
}

/// In safe builds: the instruction is accounted for by a walk (`Check.checkCovered`, kernel §9).
fn noteWalked(f: *Frame, inst: u32) void {
    if (!safety) return;
    const w = &f.m.walked;
    if (inst < w.bit_length) w.set(inst);
}

/// A spread chain's calls and their callees, down to its items: the
/// construction rule (rule 4) accounts for them, not a call of their code.
fn noteChain(f: *Frame, inst: u32, items: []const [2]u32) void {
    if (!safety) return;
    for (items) |it| if (it[0] == inst) return;
    f.noteWalked(inst);
    const m = f.m;
    if (m.tags[inst] != .call) return;
    f.noteWalked(m.datas[inst].lhs);
    for (m.bir.extraSlice(m.bir.subRange(@fromBackingInt(m.datas[inst].rhs)), Inst.Index)) |a| f.noteChain(a.int(), items);
}

/// The function declaration `t`, which host JavaScript can call with values
/// that it still holds (a `--library` build exports it, kernel §6.14): a
/// function in the default location, where `inst` names it.
pub fn walkExported(f: *Frame, t: [2]u32, inst: u32) Error!void {
    try f.flowTop(try f.node(.{ .tag = .fnref, .a = t[0], .b = t[1] }), inst);
}

fn layoutLen(f: *Frame, place: PlaceId) Error!usize {
    return f.m.loc.layouts.items[try f.m.loc.layoutOf(place)].len;
}

// ---- values --------------------------------------------------------------------

fn node(f: *Frame, n: Node) Error!Val {
    try f.nodes.append(f.gpa, n);
    return @intCast(f.nodes.items.len - 1);
}

fn refVal(f: *Frame, root: u32, path: u32) Error!Val {
    return f.node(.{ .tag = .ref, .place = f.m.loc.paths.items[path].place, .a = root, .b = path });
}

fn rootVal(f: *Frame, root: u32) Error!Val {
    const r = f.roots.items[root];
    // A value of a type with no location holds no cell that the frame can
    // name, but a cast can put one there (a list read as an `Int`), which
    // escaped where it was put (`narrowed`): it holds `outside`, never
    // nothing (research report 148).
    if (f.m.loc.layouts.items[r.layout].len == 0) return v_outside;
    return f.refVal(root, r.path);
}

/// One of the values `vs`; `ctxs[k]` is the arm of a `case` that `vs[k]` is the value of, or `none`.
fn joinVal(f: *Frame, place: PlaceId, vs: []const Val, ctxs: []const u32) Error!Val {
    var n: usize = 0;
    var one: Val = v_none;
    for (vs) |v| {
        if (v == v_none) continue;
        if (n != 0 and v == one) continue;
        one = v;
        n += 1;
    }
    if (n == 0) return v_none;
    if (n == 1 and ctxs.len == 0) return one;
    const start: u32 = @intCast(f.lists.items.len);
    var count: u32 = 0;
    for (vs, 0..) |v, k| if (v != v_none) {
        try f.lists.append(f.gpa, v);
        try f.lists.append(f.gpa, if (k < ctxs.len) ctxs[k] else none);
        count += 1;
    };
    return f.node(.{ .tag = .join, .place = place, .a = start, .b = count });
}

/// Whether the join's value `ki` can be the value while the write in judgement runs.
fn armLive(f: *const Frame, n: Node, ki: usize) bool {
    const ctx = f.lists.items[n.a + 2 * ki + 1];
    return f.judge_ctx == none or ctx == none or f.compatible(ctx, f.judge_ctx);
}

fn newRoot(f: *Frame, kind: RootKind, place: PlaceId, inst: u32) Error!u32 {
    const layout = try f.m.loc.layoutOf(place);
    const n = f.m.loc.layouts.items[layout].len;
    var r: Root = .{ .kind = kind, .place = place, .layout = layout, .inst = inst, .path = try f.m.loc.pathRoot(place) };
    switch (kind) {
        .param, .capture, .local => r.cells = (try f.innerOf(layout)).len != 0,
        .answer, .fresh, .outside => {},
    }
    switch (kind) {
        .param, .capture => {
            r.ent = @intCast(f.pflags.items.len);
            try f.pflags.appendNTimes(f.gpa, 0, n);
            r.linear = .yes;
        },
        .local => {
            r.ent = @intCast(f.rents.items.len);
            try f.rents.appendNTimes(f.gpa, .{ .kind = .own }, n);
        },
        // One cell: nothing of it is at two places.
        .answer, .fresh => r.linear = .yes,
        .outside => unreachable, // root 0, made by `init`
    }
    try f.roots.append(f.gpa, r);
    return @intCast(f.roots.items.len - 1);
}

/// The root of the cell that the code `holder`'s contract, read at the
/// location `key`, names `fresh(k)`: one root for each `(key, holder, k)` in
/// this frame, so the same cell read through two sources of one call is one
/// atom (kernel §4.2). The atom is appended to `out`; `escaped` notes its
/// escape. `draft` says the contract is a draft of a group in its rounds.
fn freshAtom(f: *Frame, key: u64, holder: u64, draft: bool, k: u32, escaped: bool, point: u32, out: *std.ArrayList(Atom)) Error!void {
    // A key names the path of holders from the walk's root: a judgment of
    // `flow` in work that reads one reads all that is above its use.
    f.ctx_floor = 0;
    const fk: FreshKey = .{ .key = key, .holder = holder, .k = k };
    const got = try f.fresh_roots.getOrPut(f.gpa, fk);
    if (!got.found_existing) {
        // One place for every fresh root: its atoms have one path to compare,
        // and the root is never a value, so its layout is not read.
        const root = try f.newRoot(.fresh, f.m.var_place, none);
        f.roots.items[root].call = true;
        got.value_ptr.* = root;
        // The cell's name in this frame's own contract: the location, the
        // holder and the holder's site. A holder whose contract is a draft
        // names its cells by the location and itself alone, so the names of a
        // recursion do not grow with the rounds and the rounds settle.
        const kh = std.hash.Wyhash.hash(key, std.mem.asBytes(&holder));
        f.roots.items[root].site = if (draft) kh else std.hash.Wyhash.hash(kh, std.mem.asBytes(&k));
    }
    const root = got.value_ptr.*;
    const a: Atom = .{ .root = root, .path = f.roots.items[root].path, .e = 0 };
    try out.append(f.gpa, a);
    // The cell escaped in the callee: it is held there, so no write of it is
    // accepted here. Once per root: a joined contract can name one site both ways.
    if (escaped and !f.roots.items[root].escaped) {
        f.roots.items[root].escaped = true;
        const at: u32 = @intCast(f.esc_atoms.items.len);
        try f.esc_atoms.append(f.gpa, a);
        try f.escapes.append(f.gpa, .{ .start = at, .len = 1, .point = point, .ctx = f.cur_ctx });
    }
}

/// The allocation site of this frame's contract that the own cell of root
/// `root` at entry `e` is (kernel §4.2): a cell the frame made is named by
/// the instruction that made it and the entry; a cell a callee made by the
/// call and the callee's site (`freshAtom`). The same name gives the same
/// number in every round of a group (`Mod.siteId`).
fn freshId(f: *Frame, root: u32, e: u32) Error!u16 {
    const r = f.roots.items[root];
    const name = switch (r.kind) {
        .fresh => r.site,
        .local => std.hash.Wyhash.hash(r.inst, std.mem.asBytes(&e)),
        .outside, .param, .capture, .answer => unreachable, // no own cell
    };
    return try f.m.siteId(name);
}

const outside_atom: Atom = .{ .root = 0, .path = 0, .e = 0 };

fn overlap(f: *const Frame, a: Atom, b: Atom) bool {
    return a.root == b.root and a.root != 0 and a.e == b.e and !posApart(a, b) and f.comparable(a.path, b.path);
}

/// Whether two atoms were read at two positions of one match of a list
/// pattern (`listParts`): two cells, though one location names both
/// (kernel §4.4, *The parts of a list pattern are apart*).
fn posApart(a: Atom, b: Atom) bool {
    return a.pos != none and b.pos != none and a.pos != b.pos and a.pos >> pos_bits == b.pos >> pos_bits;
}

/// The bits of `Atom.pos` that hold the position; the rest hold the match.
const pos_bits = 8;

/// Whether one of two paths is a prefix of the other (`Loc.Table.comparable`).
/// The climb of the deeper one to the other's depth is work (kernel §8): a
/// path into a recursive type is as deep as the chain of projections that
/// made it, so one climb can cost hundreds of steps. It is one unit and one
/// for each four steps (`Loc.scanUnits`), past the first. The answer is
/// exact past the budget too; the declaration has given up by then.
fn comparable(f: *const Frame, a: u32, b: u32) bool {
    if (a == b) return true;
    const ps = f.m.loc.paths.items;
    const da = ps[a].depth;
    const db = ps[b].depth;
    const climb = if (da > db) da - db else db - da;
    if (climb >= 4) _ = f.charge(climb / 4);
    return f.m.loc.comparable(a, b);
}

/// Whether path `a` is `b` or above it (`Loc.Table.pathPrefix`), with its
/// climb counted as `comparable` counts it.
fn pathPrefix(f: *const Frame, a: u32, b: u32) bool {
    const ps = f.m.loc.paths.items;
    const da = ps[a].depth;
    const db = ps[b].depth;
    if (db > da and db - da >= 4) _ = f.charge((db - da) / 4);
    return f.m.loc.pathPrefix(a, b);
}

/// `overlapAny` of `xs` and the write in judgement `ys`: indexed when
/// `indexWrite` indexed it.
fn overlapWrite(f: *Frame, xs: []const Atom, ys: []const Atom) bool {
    if (f.wIndexed(ys)) {
        for (xs) |x| if (f.overlapIndexed(x)) return true;
        return false;
    }
    return f.overlapAny(xs, ys);
}

fn overlapAny(f: *const Frame, xs: []const Atom, ys: []const Atom) bool {
    for (xs) |x| {
        // Each comparison made is work (kernel §8); past the budget the two
        // can share a cell.
        if (f.charge(ys.len)) return true;
        for (ys) |y| if (f.overlap(x, y)) return true;
    }
    return false;
}

/// Whether root `root` holds each cell of another root once, as `deriveLinear`
/// decided. An undecided root is read as `no`; a safe build asserts that no
/// reader meets one (kernel §4.4).
fn isLinear(f: *const Frame, root: u32) bool {
    const l = f.roots.items[root].linear;
    if (safety) std.debug.assert(l != .undecided);
    return l == .yes;
}

/// Whether one cell can be in both parts of one summary location. Two
/// answers of one function parameter (two calls) are two roots, so they are
/// not one cell by this test: the caller that knows the function decides
/// (`answerOfCode`). One answer at two places is one cell at two places.
///
/// Two cells read through one root that holds each cell once (`linear`) are
/// one cell only when that root's own atoms say so: its parts are apart.
fn dupOverlap(f: *const Frame, xs: []const Atom, ys: []const Atom) bool {
    for (xs) |x| {
        // Each comparison made is work (kernel §8); past the budget one
        // cell is at two places.
        if (f.charge(ys.len)) return true;
        for (ys) |y| {
            if (!f.overlap(x, y)) continue;
            if (f.viaApart(x, y)) continue;
            return true;
        }
    }
    return false;
}

/// Whether two overlapping atoms were read through two apart parts of one
/// root the frame made that holds each cell once (`linear`): then they are
/// two cells though one atom names both. Two reads of one part of it (or of
/// a part and a part below it) are one cell: `[ a, a ]` with `a` read out of
/// a list the frame made.
fn viaApart(f: *const Frame, x: Atom, y: Atom) bool {
    if (f.via2Apart(x, y)) return true;
    if (x.via == none or x.via != y.via or !f.isLinear(x.via)) return false;
    return x.via_e != y.via_e or !f.comparable(x.via_path, y.via_path);
}

/// Whether two overlapping atoms were read last through two entries of one
/// root the frame made that holds each cell once (kernel §4.4, *Two readings
/// through a later root*): the root's claim that its entries hold two cells
/// is about its own entries, whichever root the atoms were first read
/// through. A part and a part below it in one entry are not told apart here.
fn via2Apart(f: *const Frame, x: Atom, y: Atom) bool {
    if (x.via2 == none or x.via2 != y.via2 or x.via2_e == y.via2_e) return false;
    return f.roots.items[x.via2].linear == .yes;
}

/// The parts of one run that `partDup` tests, each against the parts before
/// it: `out[at..]` is the run, and `parts` its parts, in order, each where
/// the one before it ends. Whether one of them holds a cell an earlier one
/// holds: a large run is tested by `runsShare`, linear in its atoms.
fn partDup(f: *const Frame, out: []const Atom, at: usize, parts: []const [2]u32) Error!bool {
    if (out.len - at > share_small) return f.runsShare(out, parts, null);
    if (parts.len > 1) try f.checkShare(out, parts, null);
    var dup = false;
    for (parts) |p| if (p[0] > at and f.dupOverlap(out[at..p[0]], out[p[0]..p[1]])) {
        dup = true;
    };
    return dup;
}

// ---- the one duplicate test of a set of runs ------------------------------------

/// The scratch of `runsShare`, one for the module (`Mod.share`), cleared for each test.
pub const ShareScratch = struct {
    /// Per cell `(root, entry)`: its group.
    groups: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Per group: its last atom (its atoms are a list through `prev`), its
    /// size, its shallowest path's depth, and its tables (`Table`), or
    /// `none` while it is small.
    last: std.ArrayList(u32) = .empty,
    size: std.ArrayList(u32) = .empty,
    mind: std.ArrayList(u32) = .empty,
    table: std.ArrayList(u32) = .empty,
    /// Per atom of the test (its root is not `outside`): the atom, its run,
    /// its group, and the atom before it in its group.
    atoms: std.ArrayList(Atom) = .empty,
    run_of: std.ArrayList(u32) = .empty,
    group_of: std.ArrayList(u32) = .empty,
    prev: std.ArrayList(u32) = .empty,
    /// The tables of the large groups: per table and path, a few atoms there
    /// (`PathSums`). A group has two tables, of all its atoms and of those of
    /// a selected run, and two for each `(via, via_e)` of its atoms read
    /// through a part of a root that holds each cell once (`parts`).
    paths: std.AutoHashMapUnmanaged([2]u32, PathSums) = .empty,
    parts: std.AutoHashMapUnmanaged([3]u32, u32) = .empty,
    tables: u32 = 0,

    pub fn deinit(s: *ShareScratch, gpa: Allocator) void {
        s.groups.deinit(gpa);
        s.last.deinit(gpa);
        s.size.deinit(gpa);
        s.mind.deinit(gpa);
        s.table.deinit(gpa);
        s.atoms.deinit(gpa);
        s.run_of.deinit(gpa);
        s.group_of.deinit(gpa);
        s.prev.deinit(gpa);
        s.paths.deinit(gpa);
        s.parts.deinit(gpa);
    }

    fn clear(s: *ShareScratch) void {
        s.groups.clearRetainingCapacity();
        s.last.clearRetainingCapacity();
        s.size.clearRetainingCapacity();
        s.mind.clearRetainingCapacity();
        s.table.clearRetainingCapacity();
        s.atoms.clearRetainingCapacity();
        s.run_of.clearRetainingCapacity();
        s.group_of.clearRetainingCapacity();
        s.prev.clearRetainingCapacity();
        s.paths.clearRetainingCapacity();
        s.parts.clearRetainingCapacity();
        s.tables = 0;
    }
};

/// What a table keeps of one path: up to two atoms at the path (`at`) and at
/// or below it (`below`), of two different `via` keys (`viaKey`).
const PathSums = struct { at: [2]u32 = .{ none, none }, below: [2]u32 = .{ none, none } };

/// A group of at most this many atoms is tested in pairs: each atom costs at
/// most this many comparisons, so the test stays linear in the atoms.
const share_pairs_max = 32;

/// A set of runs with at most this many atoms in all is tested in pairs, as
/// before `runsShare` (kernel §8): the test costs what it did, and a safe
/// build checks that `runsShare` answers the same (`checkShare`).
const share_small = 64;

/// Whether two different runs of `runs` (ranges of `atoms`) hold one cell: two
/// atoms, one in each, that overlap and were not read through two apart parts
/// of one root (`dupOverlap`). With `sel`, only a pair with at least one
/// selected run counts. It answers what the test in pairs of every two runs
/// answers, the one duplicate test of kernel §4.4, in time about linear in
/// the atoms (kernel §8). The runs are taken one at a time: each atom of a
/// run is tested against the atoms of the runs before it, and then they are
/// added. The test ends at the first pair that is one cell.
///
/// - Two atoms can overlap only when they have one root and one entry, so each
///   atom is in the group of its `(root, entry)`, one lookup, and is tested
///   only against its group. `outside` overlaps nothing.
/// - While a group holds at most `share_pairs_max` atoms, an atom is compared
///   with each.
/// - A larger group keeps tables of its atoms by path (`PathSums`): an atom
///   looks up its own path for an atom at it or below it, and each path above
///   its own to the group's shallowest for one at it. Two atoms at comparable
///   paths are one cell unless both were read through two apart parts of one
///   root that holds each cell once (`viaApart`): the same `via`, and another
///   `via_e` or a `via_path` that is not comparable. So each path keeps two
///   atoms of two different `via` keys, and one of them is one cell with the
///   atom, if any atom there is whose `via` is not the atom's. Atoms of the
///   same `via` and `via_e` have their own table, and a pair found there is
///   tested for its `via_path`; when it fails, the atom is compared with each
///   atom of its group of the same `via` and `via_e`.
///
/// Each atom grouped is a lookup, each path looked up or added to is one, and
/// each pair compared is a unit; past the budget the runs share a cell.
fn runsShare(f: *const Frame, atoms: []const Atom, runs: []const [2]u32, sel: ?[]const bool) Error!bool {
    return f.shareWith(atoms, runs, sel, true, share_pairs_max);
}

/// `runsShare`, counted when `charged` (a safe build's check counts
/// nothing), with groups of more than `pairs_max` atoms tested by tables.
fn shareWith(f: *const Frame, atoms: []const Atom, runs: []const [2]u32, sel: ?[]const bool, comptime charged: bool, pairs_max_in: u32) Error!bool {
    const m = f.m;
    const gpa = m.gpa;
    const s = &m.share;
    s.clear();
    if (runs.len < 2) return false;
    // The tables keep two atoms of a path by their `via` alone, and an atom
    // with a position can be apart from one of them (`posApart`): a set
    // that has one is tested in pairs (kernel §4.4).
    var pairs_max = pairs_max_in;
    for (runs) |r| for (atoms[r[0]..r[1]]) |a| if (a.pos != none) {
        pairs_max = std.math.maxInt(u32);
    };
    // The largest run is taken last: its atoms are only tested, never added.
    var last: usize = 0;
    for (runs, 0..) |r, ri| if (r[1] - r[0] > runs[last][1] - runs[last][0]) {
        last = ri;
    };
    for (0..runs.len) |k| {
        const ri = if (k == runs.len - 1) last else if (k >= last) k + 1 else k;
        const r = runs[ri];
        const first: u32 = @intCast(s.atoms.items.len);
        // Each atom of the run against the runs before it.
        for (atoms[r[0]..r[1]]) |a| {
            if (a.root == 0) continue;
            if (charged and f.charge(Loc.lookup_units)) return true;
            const i: u32 = @intCast(s.atoms.items.len);
            try s.atoms.append(gpa, a);
            try s.run_of.append(gpa, @intCast(ri));
            try s.prev.append(gpa, none);
            const got = try s.groups.getOrPut(gpa, @as(u64, a.root) << 32 | a.e);
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(s.last.items.len);
                try s.last.append(gpa, none);
                try s.size.append(gpa, 0);
                try s.mind.append(gpa, m.loc.paths.items[a.path].depth);
                try s.table.append(gpa, none);
            }
            const g = got.value_ptr.*;
            try s.group_of.append(gpa, g);
            if (s.size.items[g] == 0) continue;
            const mine_sel = if (sel) |sl| sl[ri] else true;
            if (s.table.items[g] == none) {
                if (try f.shareEach(g, i, sel, false, charged)) return true;
                continue;
            }
            switch (try f.shareTables(g, i, mine_sel, charged)) {
                .no => {},
                .yes => return true,
                .each => if (try f.shareEach(g, i, sel, true, charged)) return true,
                .all => if (try f.shareEach(g, i, sel, false, charged)) return true,
            }
        }
        // Then the run's atoms join their groups.
        for (first..s.atoms.items.len) |ii| {
            const i: u32 = @intCast(ii);
            const g = s.group_of.items[i];
            s.prev.items[i] = s.last.items[g];
            s.last.items[g] = i;
            s.size.items[g] += 1;
            s.mind.items[g] = @min(s.mind.items[g], m.loc.paths.items[s.atoms.items[i].path].depth);
            if (s.table.items[g] != none) {
                if (try f.shareAdd(g, i, sel, charged)) return true;
            } else if (s.size.items[g] > pairs_max) {
                // A large group: its tables, from now on.
                s.table.items[g] = s.tables;
                s.tables += 2;
                var j = s.last.items[g];
                while (j != none) : (j = s.prev.items[j]) if (try f.shareAdd(g, j, sel, charged)) return true;
            }
        }
    }
    return false;
}

/// Compare atom `i` with each atom of its group `g` (of runs before its own),
/// or, with `same_part`, each of them of its `via` and `via_e`.
fn shareEach(f: *const Frame, g: u32, i: u32, sel: ?[]const bool, same_part: bool, comptime charged: bool) Error!bool {
    const s = &f.m.share;
    if (charged and f.charge(s.size.items[g])) return true;
    const x = s.atoms.items[i];
    const mine_sel = if (sel) |sl| sl[s.run_of.items[i]] else true;
    var j = s.last.items[g];
    while (j != none) : (j = s.prev.items[j]) {
        const y = s.atoms.items[j];
        if (!mine_sel) if (sel) |sl| if (!sl[s.run_of.items[j]]) continue;
        if (same_part and !(y.via == x.via and y.via_e == x.via_e)) continue;
        if (f.atomsShare(x, y, charged)) return true;
    }
    return false;
}

/// The `via` key of atom `a` (kernel §4.4): 0 when no other atom can be apart
/// from it (`viaApart`), else its `via` and one.
fn viaKey(f: *const Frame, a: Atom) u32 {
    if (a.via == none or f.roots.items[a.via].linear != .yes) return 0;
    return a.via + 1;
}

/// The table of group `g`'s atoms read through `a`'s part, as `parts` has it
/// (two ids: of all, and of a selected run); `none` when there is none.
fn partTable(f: *const Frame, g: u32, a: Atom, make: bool) Error!u32 {
    const s = &f.m.share;
    if (!make) return s.parts.get(.{ g, a.via, a.via_e }) orelse none;
    const got = try s.parts.getOrPut(f.m.gpa, .{ g, a.via, a.via_e });
    if (!got.found_existing) {
        got.value_ptr.* = s.tables;
        s.tables += 2;
    }
    return got.value_ptr.*;
}

const TablesShare = enum { no, yes, each, all };

/// The test of atom `i` against the tables of its group `g`.
fn shareTables(f: *const Frame, g: u32, i: u32, mine_sel: bool, comptime charged: bool) Error!TablesShare {
    const s = &f.m.share;
    const x = s.atoms.items[i];
    const k = f.viaKey(x);
    // A selected atom pairs with any; another only with a selected one.
    const side: u32 = if (mine_sel) 1 else 0;
    // An atom of another `via` key is one cell with `x`, unless the two were
    // read last through two entries of one root that holds each cell once
    // (`via2Apart`), which the keys do not say: then each atom of the group.
    if (try f.shareLook(s.table.items[g] + side, g, i, k, charged)) |y| {
        if (f.atomsShare(x, s.atoms.items[y], charged)) return .yes;
        return if (f.via2Apart(x, s.atoms.items[y])) .all else .each;
    }
    if (k == 0) return .no;
    const pt = try f.partTable(g, x, false);
    if (pt == none) return .no;
    if (try f.shareLook(pt + side, g, i, 0, charged)) |y| return if (f.atomsShare(x, s.atoms.items[y], charged)) .yes else .each;
    return .no;
}

/// An atom of table `t` at a path comparable with atom `i`'s whose `via` key
/// is not `k` (any, when `k` is 0): at or below `i`'s path, or at a path
/// above it to group `g`'s shallowest.
fn shareLook(f: *const Frame, t: u32, g: u32, i: u32, k: u32, comptime charged: bool) Error!?u32 {
    const s = &f.m.share;
    const ps = f.m.loc.paths.items;
    const x = s.atoms.items[i];
    const mind = s.mind.items[g];
    const depth = ps[x.path].depth;
    if (charged and f.charge((1 + depth -| mind) * Loc.lookup_units)) return i;
    if (s.paths.get(.{ t, x.path })) |sum| if (f.shareFit(sum.below, k)) |y| return y;
    if (depth <= mind) return null;
    var q = ps[x.path].parent;
    while (true) {
        if (s.paths.get(.{ t, q })) |sum| if (f.shareFit(sum.at, k)) |y| return y;
        if (ps[q].depth <= mind) return null;
        q = ps[q].parent;
    }
}

/// Of two atoms of two different `via` keys, one whose key is not `k` (any, when `k` is 0).
fn shareFit(f: *const Frame, two: [2]u32, k: u32) ?u32 {
    const s = &f.m.share;
    if (two[0] == none) return null;
    if (k == 0 or f.viaKey(s.atoms.items[two[0]]) != k) return two[0];
    return if (two[1] == none) null else two[1];
}

/// Atom `i` joins the tables of its group `g`: at its own path, and below
/// each path from its own up to the root's. True past the budget.
fn shareAdd(f: *const Frame, g: u32, i: u32, sel: ?[]const bool, comptime charged: bool) Error!bool {
    const s = &f.m.share;
    const x = s.atoms.items[i];
    const selected = if (sel) |sl| sl[s.run_of.items[i]] else true;
    const k = f.viaKey(x);
    const pt = if (k == 0) none else try f.partTable(g, x, true);
    const depth = f.m.loc.paths.items[x.path].depth;
    const ts: u64 = (@as(u64, 1) + @intFromBool(selected)) * (@as(u64, 1) + @intFromBool(pt != none));
    if (charged and f.charge(ts * (1 + depth) * Loc.lookup_units)) return true;
    const base = s.table.items[g];
    // The table of all atoms, and of those of a selected run.
    try f.shareNote(base + 1, i, k);
    if (selected) try f.shareNote(base, i, k);
    if (pt != none) {
        try f.shareNote(pt + 1, i, 0);
        if (selected) try f.shareNote(pt, i, 0);
    }
    return false;
}

/// Atom `i`, of `via` key `k`, at its path in table `t` and below each path above it.
fn shareNote(f: *const Frame, t: u32, i: u32, k: u32) Error!void {
    const s = &f.m.share;
    const ps = f.m.loc.paths.items;
    var q = s.atoms.items[i].path;
    var own = true;
    while (true) {
        const got = try s.paths.getOrPut(f.m.gpa, .{ t, q });
        if (!got.found_existing) got.value_ptr.* = .{};
        if (own) f.shareKeep(&got.value_ptr.at, i, k);
        f.shareKeep(&got.value_ptr.below, i, k);
        own = false;
        if (ps[q].depth == 0) return;
        q = ps[q].parent;
    }
}

/// Keep atom `i`, of `via` key `k`, among two atoms of two different keys.
fn shareKeep(f: *const Frame, two: *[2]u32, i: u32, k: u32) void {
    if (two[0] == none) {
        two[0] = i;
    } else if (two[1] == none and f.viaKey(f.m.share.atoms.items[two[0]]) != k) {
        two[1] = i;
    }
}

/// Whether two atoms of one `(root, entry)` are one cell: they overlap, and
/// were not read through two apart parts of one root (`dupOverlap`).
fn atomsShare(f: *const Frame, x: Atom, y: Atom, comptime charged: bool) bool {
    if (charged) return f.overlap(x, y) and !f.viaApart(x, y);
    const loc = &f.m.loc;
    if (!(x.root == y.root and x.root != 0 and x.e == y.e and !posApart(x, y) and loc.comparable(x.path, y.path))) return false;
    // `viaApart`, with no count and no assertion: the check reads what the test reads.
    if (f.via2Apart(x, y)) return false;
    if (x.via == none or x.via != y.via or f.roots.items[x.via].linear != .yes) return true;
    return !(x.via_e != y.via_e or !loc.comparable(x.via_path, y.via_path));
}

/// In safe builds: `runsShare` answers what the test in pairs of every two
/// runs answers, on a set small enough to test both ways (kernel §9), with
/// its groups compared in pairs and with each tested by tables. No way counts
/// here; past the budget the counted test said yes, and no answer is checked.
fn checkShare(f: *const Frame, atoms: []const Atom, runs: []const [2]u32, sel: ?[]const bool) Error!void {
    if (!safety or f.m.steps_over) return;
    var old = false;
    pairs: for (runs, 0..) |r1, i| for (runs[i + 1 ..], i + 1..) |r2, j| {
        if (sel) |sl| if (!sl[i] and !sl[j]) continue;
        for (atoms[r1[0]..r1[1]]) |x| for (atoms[r2[0]..r2[1]]) |y| if (f.atomsShare(x, y, false)) {
            old = true;
            break :pairs;
        };
    };
    std.debug.assert(old == try f.shareWith(atoms, runs, sel, false, share_pairs_max));
    std.debug.assert(old == try f.shareWith(atoms, runs, sel, false, 0));
}

/// Decide `linear` for root `root`, the one writer of it (kernel §4.4): no
/// entry is `twice`, and no two entries hold one cell. `claim` is the claim
/// of a callee's contract for a call's result, which the frame's atoms
/// cannot see inside of (the callee splits one summary location of its
/// argument over two of its result's): `null` where the frame made the root
/// itself and its own atoms decide. The claim covers the sources the callee
/// saw as atoms, never an answer of a function parameter: `answers` says
/// which entries hold one, and a pair of entries with one is tested here.
fn deriveLinear(f: *Frame, root: u32, claim: ?bool, answers: []const bool) Error!void {
    return f.deriveLinearSplit(root, claim, answers, null);
}

/// `deriveLinear`, where `split` gives, per entry, the wide entry of the
/// callee's result it is at when another entry is at it too, or `none`: the
/// callee's claim does not cover two entries of one such group, so each pair
/// of them that can hold one cell (`canShare`) is tested (kernel §3.4).
fn deriveLinearSplit(f: *Frame, root: u32, claim: ?bool, answers: []const bool, split: ?[]const u32) Error!void {
    const r = f.roots.items[root];
    var linear = claim orelse true;
    const n = f.m.loc.layouts.items[r.layout].len;
    for (0..n) |e| if (f.rents.items[r.ent + e].twice) {
        linear = false;
    };
    // The entries that hold an atom: only they can share a cell.
    var held: std.ArrayList(u32) = .empty;
    defer held.deinit(f.gpa);
    if (linear) for (0..n) |e| if (f.rents.items[r.ent + e].len != 0) try held.append(f.gpa, @intCast(e));
    // With the callee's claim, only a pair with an answer of a function
    // parameter is tested: the first of each pair is such an entry.
    var firsts: std.ArrayList(u32) = .empty;
    defer firsts.deinit(f.gpa);
    const grouped = struct {
        fn at(sp: ?[]const u32, e: u32) bool {
            const x = sp orelse return false;
            return x[e] != none;
        }
    }.at;
    if (linear) for (held.items) |e| if (claim == null or answers[e] or grouped(split, e)) try firsts.append(f.gpa, e);
    // A large set of entries is tested by `runsShare`, linear in its atoms.
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    var sel: std.ArrayList(bool) = .empty;
    defer sel.deinit(f.gpa);
    var total: usize = 0;
    if (linear) for (held.items) |e| {
        const a = f.rents.items[r.ent + e];
        try runs.append(f.gpa, .{ a.start, a.start + a.len });
        if (claim != null) try sel.append(f.gpa, answers[e] or grouped(split, e));
        total += a.len;
    };
    const sl: ?[]const bool = if (claim != null) sel.items else null;
    if (linear and total > share_small) {
        linear = !try f.runsShare(f.atoms.items, runs.items, sl);
        f.roots.items[root].linear = if (linear) .yes else .no;
        return;
    }
    if (linear) try f.checkShare(f.atoms.items, runs.items, sl);
    if (linear) outer: for (firsts.items, 0..) |e1, i| {
        const a1 = f.rents.items[r.ent + e1];
        // Without a claim the pairs are each two entries once; with one, an
        // answer's entry and every other entry.
        const seconds = if (claim == null) held.items[i + 1 ..] else held.items;
        // Each pair of entries is work of its own (kernel §8); past the
        // budget the root is not linear.
        if (f.charge(seconds.len)) {
            linear = false;
            break :outer;
        }
        for (seconds) |e2| {
            if (e2 == e1) continue;
            // A pair the claim covers: the first is only of a group, and the
            // second is at another entry of the callee, or of a kind that
            // holds no cell of the first's (two fields' slots, a slot and a list).
            if (claim != null and !answers[e1] and !answers[e2]) {
                const sp = split.?;
                if (sp[e2] != sp[e1]) continue;
                const es = f.m.loc.layoutEntries(r.layout);
                if (!canShare(f.m, es[e1], es[e2])) continue;
            }
            const a2 = f.rents.items[r.ent + e2];
            if (f.dupOverlap(f.atoms.items[a1.start..][0..a1.len], f.atoms.items[a2.start..][0..a2.len])) {
                linear = false;
                break :outer;
            }
        }
    };
    f.roots.items[root].linear = if (linear) .yes else .no;
}

/// Append `f.atoms[start..][0..len]` to `out`, which can be `f.atoms` itself, as cells read through root `via`.
fn copyAtoms(f: *Frame, start: u32, len: u32, via: u32, via_path: u32, via_e: u32, out: *std.ArrayList(Atom)) Error!void {
    // Each atom copied is work (kernel §8): a run can hold every older name
    // of a chain of writes.
    _ = f.charge(len);
    try out.ensureUnusedCapacity(f.gpa, len);
    for (0..len) |i| {
        var a = f.atoms.items[start + i];
        // The first root that held the cell is the one whose parts tell two readings apart.
        if (via != none and a.via == none) {
            a.via = via;
            a.via_path = via_path;
            a.via_e = via_e;
        }
        // And the last, by its entries (kernel §4.4, *Two readings through a later root*).
        if (via != none) {
            a.via2 = via;
            a.via2_e = via_e;
        }
        out.appendAssumeCapacity(a);
    }
}

/// Whether atom `a` names a location of a root that the frame made whose parts are not apart.
fn twiceAt(f: *const Frame, a: Atom) bool {
    const r = f.roots.items[a.root];
    return r.kind == .local and f.rents.items[r.ent + a.e].twice;
}

fn atomEql(a: Atom, b: Atom) bool {
    return a.root == b.root and a.path == b.path and a.e == b.e and a.via == b.via and a.via_path == b.via_path and a.via_e == b.via_e and a.dead == b.dead and a.pos == b.pos and a.via2 == b.via2 and a.via2_e == b.via2_e and a.ren == b.ren;
}

/// Remove from `list.items[from..]` each atom that an earlier atom of the run
/// equals. The first of each stays, at its place in the order.
///
/// A run of atoms is a set: each test over it asks whether one atom of it
/// does something. The readers of a root copy the atoms of its entries, and a
/// cover can give one entry for each location of a type. So without this a
/// chain of calls over a type of many locations holds each atom many times,
/// and the tests in pairs of `finish` cost the square of that.
fn uniqueTail(f: *Frame, list: *std.ArrayList(Atom), from: usize) Error!void {
    const run = list.items[from..];
    if (run.len < 2) return;
    // Removing the repeats of a run is work of its own (kernel §8).
    _ = f.charge(run.len);
    var n: usize = 1;
    if (run.len <= 16) {
        for (run[1..]) |a| {
            const seen = for (run[0..n]) |b| {
                if (atomEql(a, b)) break true;
            } else false;
            if (seen) continue;
            run[n] = a;
            n += 1;
        }
        list.shrinkRetainingCapacity(from + n);
        return;
    }
    // A larger run: a set of the atoms seen, so the cost is the run and not
    // a sort of it. Each atom is a lookup in a hash table (kernel §8). The
    // module keeps one table; one far larger than the run is let go, so that
    // clearing it costs about the run.
    _ = f.charge(run.len * Loc.lookup_units);
    const seen = &f.m.uniq_seen;
    if (seen.capacity() > 64 * run.len) seen.clearAndFree(f.m.gpa) else seen.clearRetainingCapacity();
    try seen.ensureTotalCapacity(f.m.gpa, @intCast(run.len));
    n = 0;
    for (run) |a| {
        if (seen.getOrPutAssumeCapacity(a).found_existing) continue;
        run[n] = a;
        n += 1;
    }
    list.shrinkRetainingCapacity(from + n);
}

/// The atoms of root `root` at entry `re` of its layout, at or below `path`.
fn rootLeaves(f: *Frame, root: u32, path_in: u32, re: u32, out: *std.ArrayList(Atom)) Error!void {
    const r = f.roots.items[root];
    switch (r.kind) {
        .outside => try out.append(f.gpa, outside_atom),
        .param, .capture, .answer => try out.append(f.gpa, .{ .root = root, .path = path_in, .e = re }),
        .fresh => try out.append(f.gpa, .{ .root = root, .path = r.path, .e = 0 }),
        .local => {
            const ent = f.rents.items[r.ent + re];
            // A part of a location whose parts are not apart is all of it.
            const path = if (ent.twice) r.path else path_in;
            if (ent.hasOwn()) try out.append(f.gpa, .{ .root = root, .path = path, .e = re });
            switch (ent.kind) {
                // An element taken out of its list is apart from it: its old names are not read here.
                .own, .taken => {},
                // The run: the old names (`dead`) of a new name, or the cells of other roots.
                .version, .derived, .alias => try f.copyAtoms(ent.start, ent.len, root, path, re, out),
            }
            // A cell's contents in a root the frame does not follow: what any
            // holder of the handle stores there (kernel §13).
            if (r.cells and !r.tracked and (try f.innerOf(r.layout))[re]) try out.append(f.gpa, outside_atom);
        },
    }
}

/// The atoms of `v` at entry `e` of its own place's layout. True when one
/// cell can be there twice (`leavesOwn`).
fn leaves(f: *Frame, v: Val, e: u32, out: *std.ArrayList(Atom)) Error!bool {
    if (f.tick()) return false;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .outside => {
            try out.append(f.gpa, outside_atom);
            return false;
        },
        .ref, .built, .join => return f.leavesOwn(v, &.{e}, out),
        .closure, .unknown => {
            if (try f.leafHit(v, &.{}, true, out)) |dup| return dup;
            const start = out.items.len;
            // Once the walk is over (`finish`), each such value's atoms are
            // what a walk of them found the first time: a value never
            // changes once it is made, and every capture is bound by then.
            // `finish` reads the result once for each of its locations, and
            // a value of no claim holds the same cells at each (kernel §8;
            // research report 159).
            if (f.finished and v < f.whole_at.items.len and f.whole_at.items[v][0] != none) {
                const hit = f.whole_at.items[v];
                _ = f.charge(hit[1]);
                try out.appendSlice(f.gpa, f.whole_buf.items[hit[0]..][0..hit[1]]);
                return false;
            }
            f.leaf_nest += 1;
            if (n.tag == .closure) {
                const c = f.codes.items[n.a];
                for (0..c.ncaps) |ki| _ = try f.allLeaves(try f.capVal(c, ki), out);
            } else {
                // No claim, and each cell of the values that it can be made of.
                try out.append(f.gpa, outside_atom);
                for (0..n.b) |ki| _ = try f.allLeaves(f.lists.items[n.a + ki], out);
            }
            try f.leafKeep(v, &.{}, true, out, start, false);
            if (f.finished and !f.m.steps_over) {
                const at: u32 = @intCast(f.whole_buf.items.len);
                try f.whole_buf.appendSlice(f.gpa, out.items[start..]);
                if (v >= f.whole_at.items.len) try f.whole_at.appendNTimes(f.gpa, .{ none, 0 }, f.nodes.items.len - f.whole_at.items.len);
                f.whole_at.items[v] = .{ at, @intCast(out.items.len - start) };
            }
            return false;
        },
        .later => unreachable, // read through `capVal` only
    }
}

/// A walk of values reaches one value by many paths (a closure that two
/// closures captured, a value in two arms of two `if`s): it walks each value
/// once for each set of entries, and copies what it found, without repeats,
/// where it reaches the value again (kernel §8). Kept while one walk of
/// values runs (`leaf_nest`). The atoms of a value are a set and its `dup`
/// is its own, so a copy is what a second walk finds.
const LeafKey = struct { v: Val, ks: u64, whole: bool };
const LeafHit = struct { start: u32, len: u32, ks_start: u32, ks_len: u32, dup: bool };

fn leafKeyOf(v: Val, ks: []const u32, all: bool) LeafKey {
    return .{ .v = v, .ks = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(ks)), .whole = all };
}

/// What the walk of values in work found for `v` at `ks`, appended to
/// `out`, and its `dup`; null when it has not walked it.
fn leafHit(f: *Frame, v: Val, ks: []const u32, all: bool, out: *std.ArrayList(Atom)) Error!?bool {
    if (f.leaf_nest == 0) return null;
    const hit = f.leaf_memo.get(leafKeyOf(v, ks, all)) orelse return null;
    if (!std.mem.eql(u32, f.leaf_ks.items[hit.ks_start..][0..hit.ks_len], ks)) return null;
    // The copy is work of its own (kernel §8).
    _ = f.charge(hit.len);
    try out.appendSlice(f.gpa, f.leaf_buf.items[hit.start..][0..hit.len]);
    return hit.dup;
}

/// The walk of `v` at `ks` found `out[start..]` and `dup`: keep it, without repeats.
fn leafKeep(f: *Frame, v: Val, ks: []const u32, all: bool, out: *std.ArrayList(Atom), start: usize, dup: bool) Error!void {
    if (f.leaf_nest == 1) {
        // The value that the walk started at: no walk reaches it again.
        f.leaf_nest = 0;
        f.leaf_memo.clearRetainingCapacity();
        f.leaf_buf.clearRetainingCapacity();
        f.leaf_ks.clearRetainingCapacity();
        return;
    }
    try f.uniqueTail(out, start);
    // The copy kept is work (kernel §8).
    _ = f.charge(out.items.len - start);
    const hit: LeafHit = .{
        .start = @intCast(f.leaf_buf.items.len),
        .len = @intCast(out.items.len - start),
        .ks_start = @intCast(f.leaf_ks.items.len),
        .ks_len = @intCast(ks.len),
        .dup = dup,
    };
    try f.leaf_buf.appendSlice(f.gpa, out.items[start..]);
    try f.leaf_ks.appendSlice(f.gpa, ks);
    try f.leaf_memo.put(f.gpa, leafKeyOf(v, ks, all), hit);
    f.leaf_nest -= 1;
    if (f.leaf_nest == 0) {
        f.leaf_memo.clearRetainingCapacity();
        f.leaf_buf.clearRetainingCapacity();
        f.leaf_ks.clearRetainingCapacity();
    }
}

/// A set of entries of one layout, in the order first added. Most sets
/// have one or two entries, so it starts in place.
const Entries = struct {
    small: [8]u32 = undefined,
    n: usize = 0,
    more: std.ArrayList(u32) = .empty,
    /// The members of a large set, by entry, so that an add costs one step
    /// and not a scan of the set (kernel §8). Empty while the set is small.
    seen: std.DynamicBitSetUnmanaged = .{},

    fn add(s: *Entries, gpa: Allocator, x: u32) Error!void {
        if (s.seen.bit_length != 0) {
            if (x >= s.seen.bit_length) try s.seen.resize(gpa, @max(x + 1, 2 * s.seen.bit_length), false);
            if (s.seen.isSet(x)) return;
            s.seen.set(x);
            try s.more.append(gpa, x);
            return;
        }
        for (s.slice()) |y| if (y == x) return;
        if (s.more.items.len == 0 and s.n < s.small.len) {
            s.small[s.n] = x;
            s.n += 1;
            return;
        }
        if (s.more.items.len == 0) try s.more.appendSlice(gpa, s.small[0..s.n]);
        try s.more.append(gpa, x);
        if (s.more.items.len > 32) {
            var top: u32 = 0;
            for (s.more.items) |y| top = @max(top, y);
            s.seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, top + 1);
            for (s.more.items) |y| s.seen.set(y);
        }
    }

    fn slice(s: *const Entries) []const u32 {
        return if (s.more.items.len != 0) s.more.items else s.small[0..s.n];
    }
};

/// The atoms of `v` at the entries `ks` of its own place's layout. True when
/// one cell can be at two of these places, or twice in one of them.
///
/// **One list reachable two ways makes its location `twice`** (research
/// report 114 §7). A summary location (the deep level of a recursive type)
/// can be fed by two parts of a construction, and also by two entries of
/// one part: the entry level and the deep level of the value that a
/// constructor holds both fold into the deep level of the constructor's
/// value. So this takes a set of entries, and asks each part for its own
/// set once: a cell at two of them is found as a cell of two parts.
///
/// Two entries of one part of a root that are one entry of the root are
/// that entry once: its atom names each of its cells, at every depth, and
/// the root's own claim says that they are apart. Two entries of a root
/// that hold one cell of another root are two places, unless the root
/// says that it holds each such cell once (`linear`, in `dupOverlap`).
fn leavesOwn(f: *Frame, v: Val, ks: []const u32, out: *std.ArrayList(Atom)) Error!bool {
    if (f.tick()) return false;
    // A part of a root walks nothing below it.
    if (f.nodes.items[v].tag == .ref) return f.leavesOwnWalk(v, ks, out);
    if (try f.leafHit(v, ks, false, out)) |dup| return dup;
    const start = out.items.len;
    f.leaf_nest += 1;
    const dup = try f.leavesOwnWalk(v, ks, out);
    try f.leafKeep(v, ks, false, out, start, dup);
    return dup;
}

/// For each entry of the layout of a construction's place, the parts of it
/// that hold a location there: `kids[off[e]..off[e + 1]]`, ascending; and the
/// parts with no projection (`whole`), which a walk reads whole.
const BuiltIndex = struct { off: []const u32, kids: []const u32, whole: []const u32 };

/// The index of the construction `v` (`BuiltIndex`), made once in the frame:
/// each part's projection is a lookup, and each entry of the part's layout a unit (kernel §8).
fn builtIndex(f: *Frame, v: Val, n: Node) Error!*const BuiltIndex {
    if (f.built_index.getPtr(v)) |hit| return hit;
    const m = f.m;
    const len = m.loc.layoutEntries(try m.loc.layoutOf(n.place)).len;
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(m.gpa);
    var reads_all: std.ArrayList(u32) = .empty;
    const last = try m.gpa.alloc(u32, len);
    defer m.gpa.free(last);
    @memset(last, none);
    _ = f.charge(n.b * Loc.lookup_units);
    for (0..n.b) |ki| {
        const k = f.kids.items[n.a + ki];
        if (k.val == v_none) continue;
        if (k.step == slot_kid) {
            // The object: it holds the record's own slots (`recordOf`).
            const es = m.loc.layoutEntries(try m.loc.layoutOf(n.place));
            _ = f.charge(Loc.scanUnits(es.len));
            for (es, 0..) |e, u| if (f.isOwnSlot(e.loc)) try pairs.append(m.gpa, .{ @intCast(u), @intCast(ki) });
            continue;
        }
        if (try m.loc.proj(n.place, Step.fromWord(k.step))) |pr| {
            _ = f.charge(pr.up.len);
            // A location of the part with no location in the whole's layout
            // (`up` is `none`) is at no entry the index can name: the part
            // is read for every entry, never for none (research report 148).
            var unplaced = false;
            for (pr.up) |u| {
                if (u == none) {
                    unplaced = true;
                    continue;
                }
                if (last[u] == ki) continue;
                last[u] = @intCast(ki);
                try pairs.append(m.gpa, .{ u, @intCast(ki) });
            }
            if (unplaced) try reads_all.append(f.gpa, @intCast(ki));
        } else try reads_all.append(f.gpa, @intCast(ki));
    }
    const off = try f.gpa.alloc(u32, len + 1);
    @memset(off, 0);
    for (pairs.items) |pk| off[pk[0] + 1] += 1;
    for (1..len + 1) |e| off[e] += off[e - 1];
    const kids = try f.gpa.alloc(u32, pairs.items.len);
    const fill = try m.gpa.dupe(u32, off[0..len]);
    defer m.gpa.free(fill);
    // The parts in ascending order within each entry: `pairs` is in the order of the parts.
    for (pairs.items) |pk| {
        kids[fill[pk[0]]] = pk[1];
        fill[pk[0]] += 1;
    }
    try f.built_index.put(f.gpa, v, .{ .off = off, .kids = kids, .whole = reads_all.items });
    return f.built_index.getPtr(v).?;
}

/// The parts of construction `v` that a walk of its entries `ks` reads, in
/// ascending order: those that hold a location at one of them, and those
/// with no projection.
fn builtKids(f: *Frame, v: Val, n: Node, ks: []const u32) Error![]const u32 {
    const ix = try f.builtIndex(v, n);
    var sel: std.ArrayList(u32) = .empty;
    try sel.appendSlice(f.gpa, ix.whole);
    for (ks) |e| try sel.appendSlice(f.gpa, ix.kids[ix.off[e]..ix.off[e + 1]]);
    // Each part found is a unit (kernel §8).
    _ = f.charge(sel.items.len + ks.len);
    std.mem.sort(u32, sel.items, {}, std.sort.asc(u32));
    var w: usize = 0;
    for (sel.items) |x| {
        if (w != 0 and sel.items[w - 1] == x) continue;
        sel.items[w] = x;
        w += 1;
    }
    return sel.items[0..w];
}

fn leavesOwnWalk(f: *Frame, v: Val, ks: []const u32, out: *std.ArrayList(Atom)) Error!bool {
    const m = f.m;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .ref => {
            const first = out.items.len;
            // The match and position of a list pattern's part, on each atom read (`listParts`).
            defer if (n.pos != none) for (out.items[first..]) |*a| {
                a.pos = n.pos;
            };
            const p = m.loc.paths.items[n.b];
            var res: Entries = .{};
            var lost = false;
            _ = f.charge(ks.len);
            for (ks) |k| {
                const re = p.to_root[k];
                if (re == none) lost = true else try res.add(f.gpa, re);
            }
            // A location of the part that the root's layout does not name
            // (`to_root` is `none`): no write may claim it, and it can hold
            // any cell of the root, so every entry of the root is read, never
            // none (research report 148).
            if (lost) {
                try out.append(f.gpa, outside_atom);
                const lr = f.roots.items[n.a];
                const rn = m.loc.layoutEntries(lr.layout).len;
                _ = f.charge(rn);
                for (0..rn) |re| try f.rootLeaves(n.a, lr.path, @intCast(re), out);
            }
            var dup = false;
            const at = out.items.len;
            const r = f.roots.items[n.a];
            var parts: std.ArrayList([2]u32) = .empty;
            defer parts.deinit(f.gpa);
            for (res.slice()) |re| {
                const before: u32 = @intCast(out.items.len);
                try f.rootLeaves(n.a, n.b, re, out);
                if (r.kind == .local and f.rents.items[r.ent + re].twice) dup = true;
                try parts.append(f.gpa, .{ before, @intCast(out.items.len) });
            }
            if (!dup and try f.partDup(out.items, at, parts.items)) dup = true;
            return dup;
        },
        .built => {
            // The parts to walk: for a few entries of a construction of many
            // parts, only the parts that hold a location at one of them
            // (`builtIndex`); else every part. A part that holds none adds
            // nothing, so the walk finds what a walk of every part finds, and
            // a walk of each entry of a record of `n` fields (`finish`)
            // costs `n` and not its square (research report 138).
            const some: ?[]const u32 = if (ks.len <= 8 and n.b > 8) try f.builtKids(v, n, ks) else null;
            const nwalk = if (some) |sk| sk.len else n.b;
            // A walk of each part is work of its own (kernel §8): each part
            // looks up its projection, `lookup_units`. Past the budget it
            // holds a cell of no frame, and no write of it stands.
            if (f.charge(nwalk * Loc.lookup_units)) {
                try out.append(f.gpa, outside_atom);
                return true;
            }
            var dup = false;
            const at = out.items.len;
            var parts: std.ArrayList([2]u32) = .empty;
            defer parts.deinit(f.gpa);
            const pes = m.loc.layoutEntries(try m.loc.layoutOf(n.place));
            const single = ks.len == 1 and pes[ks[0]].single;
            // A large set of entries reads the rank of each entry once, so
            // that a kid costs its own entries and not the whole set (kernel
            // §8): a walk of a construction costs its layout, not the layout
            // times its parts.
            var rank: []u32 = &.{};
            defer m.gpa.free(rank);
            var pairs: std.ArrayList([2]u32) = .empty;
            defer pairs.deinit(m.gpa);
            if (ks.len > 8) {
                if (f.charge(pes.len + ks.len)) {
                    try out.append(f.gpa, outside_atom);
                    return true;
                }
                rank = try m.gpa.alloc(u32, pes.len);
                @memset(rank, none);
                for (ks, 0..) |e, i| if (rank[e] == none) {
                    rank[e] = @intCast(i);
                };
            }
            for (0..nwalk) |wi| {
                const ki = if (some) |sk| sk[wi] else wi;
                const k = f.kids.items[n.a + ki];
                if (k.val == v_none) continue;
                // Past the budget the walk stops: a cell of no frame, and
                // no write of it stands.
                if (m.steps_over) {
                    try out.append(f.gpa, outside_atom);
                    return true;
                }
                const before: u32 = @intCast(out.items.len);
                if (k.step == slot_kid) {
                    // The object: the record's own slots among `ks`, at the
                    // same entries of the same layout (`recordOf`).
                    var js: Entries = .{};
                    _ = f.charge(ks.len);
                    for (ks) |e| if (f.isOwnSlot(pes[e].loc)) try js.add(f.gpa, e);
                    if (js.slice().len != 0 and try f.leavesOwn(k.val, js.slice(), out)) dup = true;
                    if (!single) try parts.append(f.gpa, .{ before, @intCast(out.items.len) });
                    continue;
                }
                if (try m.loc.proj(n.place, Step.fromWord(k.step))) |pr| {
                    // The kid's entries that these entries are made of: for
                    // each entry of `ks`, in its order, the kid's entries
                    // below it, ascending.
                    var js: Entries = .{};
                    if (rank.len == 0) {
                        _ = f.charge(ks.len);
                        for (ks) |e| for (pr.downOf(e)) |j| try js.add(f.gpa, j);
                    } else {
                        _ = f.charge(pr.up.len);
                        pairs.clearRetainingCapacity();
                        for (pr.up, 0..) |u, j| if (u != none and rank[u] != none) try pairs.append(m.gpa, .{ rank[u], @intCast(j) });
                        std.mem.sort([2]u32, pairs.items, {}, struct {
                            fn lt(_: void, x: [2]u32, y: [2]u32) bool {
                                return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
                            }
                        }.lt);
                        for (pairs.items) |pj| try js.add(f.gpa, pj[1]);
                    }
                    if (js.slice().len != 0 and try f.leavesSet(k.val, pr.child, js.slice(), out)) dup = true;
                } else if (try f.allLeaves(k.val, out)) {
                    dup = true;
                }
                if (!single) try parts.append(f.gpa, .{ before, @intCast(out.items.len) });
            }
            if (!dup and try f.partDup(out.items, at, parts.items)) dup = true;
            return dup;
        },
        .join => {
            // One of several values: each arm holds its own cells.
            var dup = false;
            for (0..n.b) |ki| {
                if (!f.armLive(n, ki)) continue;
                if (try f.leavesSet(f.lists.items[n.a + 2 * ki], n.place, ks, out)) dup = true;
            }
            return dup;
        },
        .none, .outside, .fnref, .closure, .unknown => return f.leaves(v, 0, out),
        .later => unreachable, // read through `capVal` only
    }
}

/// `leavesOwn` of `v` at the entries `js` of `place`'s layout, which can be
/// another reading of `v`'s type: each entry of `v`'s own layout that the
/// call map puts at one of them.
fn leavesSet(f: *Frame, v: Val, place: PlaceId, js: []const u32, out: *std.ArrayList(Atom)) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .outside => {
            try out.append(f.gpa, outside_atom);
            return false;
        },
        .closure, .unknown => return f.leaves(v, 0, out),
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    if (n.place == place) return f.leavesOwn(v, js, out);
    const view = try f.m.loc.layoutOf(place);
    const own = try f.m.loc.layoutOf(n.place);
    if (view == own) return f.leavesOwn(v, js, out);
    const cov = try f.m.loc.cover(view, own);
    // A wide entry of `v`'s own layout holds the cells of the view's
    // locations below it, which the map puts at another entry of the view (a
    // `Js.Value` read as a list of records, a folded payload): it is read at
    // each of them too, and none of them is single (kernel §3.4).
    const holes = try f.m.loc.holes(view, own);
    var coarse_dup = false;
    var ks: Entries = .{};
    // A few entries are looked up in the map read the other way, which is
    // made once for each pair of layouts in a frame (`coverHits`), so that a
    // reader that asks for each entry of a large layout in turn (`finish`)
    // costs the entries it reads and not the square of the layout; each
    // entry found is a step (kernel §8; research report 159). A large set of
    // entries is a mark for each entry of the view, so that the map is read
    // once, and each entry of the map is a step.
    if (js.len <= 8) {
        var hit: std.ArrayList(u32) = .empty;
        defer hit.deinit(f.gpa);
        var one: std.ArrayList(u32) = .empty;
        defer one.deinit(f.gpa);
        for (js) |j| {
            one.clearRetainingCapacity();
            try f.coverHits(view, own, cov, j, &one);
            try hit.appendSlice(f.gpa, one.items);
            if (holes) |h| if (h.read[j] != none) try hit.append(f.gpa, h.read[j]);
        }
        _ = f.charge(js.len + hit.items.len);
        // In ascending order, each once, as a scan of the map finds them.
        std.mem.sort(u32, hit.items, {}, std.sort.asc(u32));
        for (hit.items, 0..) |k, i| if (i == 0 or hit.items[i - 1] != k) try ks.add(f.gpa, k);
        if (holes) |h| for (js, 0..) |j, i| if (h.above[j] != none) {
            // A summary below a wide entry, or two locations below one.
            if (!f.m.loc.layoutEntries(view)[j].single) coarse_dup = true;
            for (js[i + 1 ..]) |j2| if (h.above[j2] == h.above[j]) {
                coarse_dup = true;
            };
        };
    } else {
        const vn = f.m.loc.layoutEntries(view).len;
        _ = f.charge(cov.len + vn + js.len);
        const in_js = try f.m.gpa.alloc(bool, vn);
        defer f.m.gpa.free(in_js);
        @memset(in_js, false);
        for (js) |j| in_js[j] = true;
        const extra = try f.m.gpa.alloc(bool, cov.len);
        defer f.m.gpa.free(extra);
        @memset(extra, false);
        // Per wide entry of `own`: how many entries of `js` it is above.
        const above_n = try f.m.gpa.alloc(u32, cov.len);
        defer f.m.gpa.free(above_n);
        @memset(above_n, 0);
        if (holes) |h| for (js) |j| {
            if (h.read[j] != none) extra[h.read[j]] = true;
            if (h.above[j] == none) continue;
            if (!f.m.loc.layoutEntries(view)[j].single) coarse_dup = true;
            above_n[h.above[j]] += 1;
            if (above_n[h.above[j]] > 1) coarse_dup = true;
        };
        for (cov, 0..) |c, k| if (c == Loc.all or (c < vn and in_js[c]) or extra[k]) try ks.add(f.gpa, @intCast(k));
    }
    // A slot of the view that `v`'s own layout has no slot for: a tuple or a
    // constructor read as a record, whose object no cell names (`slotsLost`).
    if (try f.slotsLost(view, n.place, js)) try out.append(f.gpa, outside_atom);
    if (std.debug.runtime_safety) try f.checkPlaced(view, own, n.place, cov, holes, js);
    const dup = try f.leavesOwn(v, ks.slice(), out);
    return dup or coarse_dup;
}

/// Safe builds (kernel §9): each location `j` of the reading `view` that a
/// reader of a value of layout `own` asks for is placed in the value's own
/// layout: an entry of `own` is at it (the map, `cover(view, own)`, or
/// `Loc.all`), or a wide entry of `own` above it holds it (`Loc.holes`), or
/// it is a record's slot that the value has no slot for (`slotsLost`, read
/// as `outside`), or the value's own place has the location's steps and
/// they reach a type of no cell (`Loc.emptyAlong`: `Result String b` read
/// as `Result a b`). A location placed by none of them reads as holding no
/// cell, and nothing says it holds none: a value read at a type with more
/// places than its own that no rule saw (research reports 146, 147 and 148;
/// a cast is `unknown` before it gets here, `punned`). The check counts no work.
fn checkPlaced(f: *Frame, view: u32, own: u32, own_place: PlaceId, cov: []const u32, holes: ?*const Loc.Holes, js: []const u32) Error!void {
    const m = f.m;
    // A value of a type with no location holds no cell (a cell that a cast
    // put in one escaped there, `narrowed`).
    if (m.loc.layoutEntries(own).len == 0) return;
    const ves = m.loc.layoutEntries(view);
    const seen = try f.gpa.alloc(bool, ves.len);
    defer f.gpa.free(seen);
    @memset(seen, false);
    for (cov) |c| {
        if (c == Loc.all) return;
        if (c < ves.len) seen[c] = true;
    }
    if (holes) |h| for (h.read, h.above, 0..) |r, a, j| if (r != none or a != none) {
        seen[j] = true;
    };
    for (js) |j| {
        if (seen[j]) continue;
        if (try m.loc.emptyAlong(own_place, ves[j].loc, f.gpa)) continue;
        std.debug.panic("own3: location {d} of a reading (layout {d}) has no location in the value's own layout {d}, and no wide entry above it", .{ j, view, own });
    }
}

/// Per entry `k` of layout `own`, the flags of the entries of `sig` whose
/// cells `k` holds though the map puts it at another entry (`Loc.holes`),
/// or-ed; empty when there is none. It costs the signature's layout (kernel §8).
fn holeFlags(f: *Frame, sig: u32, own: u32, flags: []const u8) Error![]u8 {
    const h = (try f.m.loc.holes(sig, own)) orelse return f.gpa.alloc(u8, 0);
    _ = f.charge(Loc.scanUnits(h.read.len));
    const out = try f.gpa.alloc(u8, f.m.loc.layoutEntries(own).len);
    @memset(out, 0);
    for (h.read, 0..) |k, j| if (k != none) {
        out[k] |= flags[j];
    };
    return out;
}

fn whole(tag: Tag) bool {
    return switch (tag) {
        .closure, .unknown => true,
        .none, .outside, .ref, .built, .join, .fnref => false,
        .later => unreachable, // read through `capVal` only
    };
}

/// A value that the walk cannot follow, made of the values `vs`: no claim,
/// and each cell of each of them at each location (research report 112
/// §2.5, the default answer). It is never "holds nothing" by default: it is
/// `outside` only when each value it is made of holds no cell of the frame,
/// which is then a fact of those values (kernel §3.2).
fn unknownOf(f: *Frame, place: PlaceId, vs: []const Val) Error!Val {
    // At a type with no location: `outside` where a value it is made of
    // holds anything (`rootVal`), else nothing.
    if (try f.layoutLen(place) == 0) {
        for (vs) |x| if (x != v_none) return v_outside;
        return v_none;
    }
    // A value of no claim is a holder the walk does not follow: each handle
    // it can hold has another holder (kernel §13).
    for (vs) |v| try f.shareVal(v, none);
    const start: u32 = @intCast(f.lists.items.len);
    for (vs) |v| if (v != v_none and v != v_outside) try f.lists.append(f.gpa, v);
    const count: u32 = @intCast(f.lists.items.len - start);
    if (count == 0) return v_outside;
    return f.node(.{ .tag = .unknown, .place = place, .a = start, .b = count });
}

/// `leaves` of `v` seen at entry `e` of `place`'s layout, which can be
/// another reading of `v`'s type. Two entries of `v` that the call map puts
/// at `e` are one set (`leavesOwn`).
fn leavesAs(f: *Frame, v: Val, place: PlaceId, e: u32, out: *std.ArrayList(Atom)) Error!bool {
    return f.leavesSet(v, place, &.{e}, out);
}

fn allLeaves(f: *Frame, v: Val, out: *std.ArrayList(Atom)) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .outside => {
            try out.append(f.gpa, outside_atom);
            return false;
        },
        .closure, .unknown => return f.leaves(v, 0, out),
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    var dup = false;
    const len = try f.layoutLen(n.place);
    for (0..len) |e| {
        if (try f.leaves(v, @intCast(e), out)) dup = true;
    }
    return dup;
}

/// Whether `v` can hold a cell of `w`.
fn reach(f: *Frame, v: Val, w: []const Atom) Error!bool {
    if (f.tick()) return true;
    switch (f.nodes.items[v].tag) {
        // No value below it.
        .none, .outside, .fnref, .ref => return f.reachWalk(v, w),
        .built, .join, .unknown, .closure => {},
        .later => unreachable, // read through `capVal` only
    }
    // A value that this walk reached already did not reach `w` (kernel §8).
    if (f.reach_nest != 0 and (try f.reach_seen.getOrPut(f.gpa, v)).found_existing) return false;
    if (f.reach_nest == 0) try f.reach_seen.put(f.gpa, v, {});
    f.reach_nest += 1;
    defer {
        f.reach_nest -= 1;
        if (f.reach_nest == 0) f.reach_seen.clearRetainingCapacity();
    }
    return f.reachWalk(v, w);
}

fn reachWalk(f: *Frame, v: Val, w: []const Atom) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .outside, .fnref => return false,
        .ref => {
            if (n.pos == none) return f.rootReach(n.a, n.b, w);
            // A list pattern's part: its atoms carry their position, which
            // `rootReach` does not read (kernel §4.4).
            // A list of its own: `w` can be a slice of `f.atoms`.
            var own: std.ArrayList(Atom) = .empty;
            defer own.deinit(f.gpa);
            _ = try f.allLeaves(v, &own);
            return f.atomsReach(own.items, w);
        },
        .built => {
            for (0..n.b) |ki| if (try f.reach(f.kids.items[n.a + ki].val, w)) return true;
            return false;
        },
        .join => {
            for (0..n.b) |ki| if (f.armLive(n, ki) and try f.reach(f.lists.items[n.a + 2 * ki], w)) return true;
            return false;
        },
        .unknown => {
            for (0..n.b) |ki| if (try f.reach(f.lists.items[n.a + ki], w)) return true;
            return false;
        },
        .closure => {
            const c = f.codes.items[n.a];
            for (0..c.ncaps) |ki| if (try f.reach(try f.capVal(c, ki), w)) return true;
            return false;
        },
        .later => unreachable, // read through `capVal` only
    }
}

fn rootReach(f: *Frame, root: u32, path: u32, w: []const Atom) Error!bool {
    const r = f.roots.items[root];
    const p = f.m.loc.paths.items[path];
    // Each target compared is work (kernel §8), and so is each climb of a
    // path and each entry of the part scanned; past the budget it reaches.
    // The write in judgement, indexed: only its atoms of this root (`w_ix`).
    const indexed = f.wIndexed(w);
    const targets = if (indexed) f.w_ix.ofRoot(root) else w;
    if (f.charge(if (indexed) @min(Loc.lookup_units + targets.len, w.len) else w.len)) return true;
    for (targets) |x| {
        if (x.root != root) continue;
        if (f.pathPrefix(path, x.path)) return true;
        if (f.pathPrefix(x.path, path)) {
            // The target's location must be at or below this part.
            if (f.charge(p.to_root.len)) return true;
            for (p.to_root) |re| if (re == x.e) return true;
        }
    }
    switch (r.kind) {
        .local => {
            const len = f.m.loc.layouts.items[r.layout].len;
            var made = false;
            if (try f.runEntries(root, &made)) |re| return f.runsReach(root, p, re, w, made);
            if (f.charge(len)) return true;
            const res = f.m.loc.layoutEntries(r.layout);
            // The entries below this part, marked once (a step each, kernel §8):
            // a record's field slot that is not below it holds no cell of it (kernel §11).
            var below: std.DynamicBitSetUnmanaged = .{};
            defer below.deinit(f.gpa);
            const has_slots = for (res) |e| {
                if (e.kind == .field) break true;
            } else false;
            if (has_slots and p.to_root.len != len) {
                if (f.charge(p.to_root.len)) return true;
                below = try std.DynamicBitSetUnmanaged.initEmpty(f.gpa, len);
                for (p.to_root) |re| if (re != none) below.set(re);
            }
            for (0..len) |i| {
                const ent = f.rents.items[r.ent + i];
                switch (ent.kind) {
                    .own, .taken => continue,
                    .alias, .derived, .version => {},
                }
                if (res[i].kind == .field and below.bit_length != 0 and !below.isSet(i)) continue;
                if (try f.runReaches(root, @intCast(i), ent, w)) return true;
            }
        },
        .answer => {
            // What the function was handed can be in its answer.
            if (root != f.skip_answer and f.atomsReach(f.answers.items[r.ent].base.items, w)) return true;
        },
        .outside, .param, .capture, .fresh => {},
    }
    return false;
}

/// The entries of a root the frame made whose runs `rootReach` reads: an
/// `alias`, `derived` or `version` entry with a run (an empty run reaches
/// nothing, `runReaches`), and whether its layout has a field slot.
const RunEntries = struct { ents: []const u32, has_slots: bool };

/// `RunEntries` of root `root`, made once, a step for each entry (kernel
/// §8), when its entries are made: `deriveLinear` ran over them, last. A
/// root's entries never change after that. Null before, and for a root of
/// at most `w_index_min` entries, which `rootReach` scans as before. A
/// scan for each part of a record of `n` fields read cost n² (research
/// report 145).
fn runEntries(f: *Frame, root: u32, made: *bool) Error!?RunEntries {
    made.* = false;
    const r = f.roots.items[root];
    if (r.linear == .undecided) return null;
    const res = f.m.loc.layoutEntries(r.layout);
    if (res.len <= w_index_min) return null;
    if (f.run_ents.items.len <= root) try f.run_ents.appendNTimes(f.gpa, null, root + 1 - f.run_ents.items.len);
    const got = &f.run_ents.items[root];
    if (got.* == null) {
        // The scan that makes the list is the one `rootReach` made each time.
        made.* = true;
        _ = f.charge(res.len);
        var ents: std.ArrayList(u32) = .empty;
        var has_slots = false;
        for (res, 0..) |e, i| {
            if (e.kind == .field) has_slots = true;
            const ent = f.rents.items[r.ent + i];
            switch (ent.kind) {
                .own, .taken => continue,
                .alias, .derived, .version => {},
            }
            if (ent.len == 0) continue;
            try ents.append(f.gpa, @intCast(i));
        }
        got.* = .{ .ents = ents.items, .has_slots = has_slots };
    }
    if (safety and res.len <= 256) {
        // The entries never change once made.
        var k: usize = 0;
        for (res, 0..) |_, i| {
            const ent = f.rents.items[r.ent + i];
            const reads = ent.len != 0 and (ent.kind == .alias or ent.kind == .derived or ent.kind == .version);
            if (!reads) continue;
            std.debug.assert(k < got.*.?.ents.len and got.*.?.ents[k] == i);
            k += 1;
        }
        std.debug.assert(k == got.*.?.ents.len);
    }
    return got.*;
}

/// `rootReach`'s test of the runs of root `root` (a root the frame made)
/// below the part at path `p`, over its `RunEntries`: the entries the scan
/// of every entry tests, in the same order.
fn runsReach(f: *Frame, root: u32, p: Loc.Path, re: RunEntries, w: []const Atom, made: bool) Error!bool {
    const r = f.roots.items[root];
    const len = f.m.loc.layouts.items[r.layout].len;
    // The list costs what the scan of every entry cost, where it was made
    // (`runEntries`), and its own entries after.
    if (!made and f.charge(@min(1 + re.ents.len, len))) return true;
    if (made and f.m.steps_over) return true;
    const res = f.m.loc.layoutEntries(r.layout);
    // The entries below this part (a step each, kernel §8): a record's
    // field slot that is not below it holds no cell of it (kernel §11).
    var below: std.DynamicBitSetUnmanaged = .{};
    defer below.deinit(f.gpa);
    if (re.has_slots and p.to_root.len != len) {
        if (f.charge(p.to_root.len)) return true;
        below = try std.DynamicBitSetUnmanaged.initEmpty(f.gpa, len);
        for (p.to_root) |x| if (x != none) below.set(x);
    }
    for (re.ents) |i| {
        if (res[i].kind == .field and below.bit_length != 0 and !below.isSet(i)) continue;
        if (try f.runReaches(root, i, f.rents.items[r.ent + i], w)) return true;
    }
    return false;
}

/// Whether a cell of `xs` can be a cell of `w`: the same cells, or the answer
/// of a function parameter that was handed one.
fn atomsReach(f: *Frame, xs: []const Atom, w: []const Atom) bool {
    if (f.wIndexed(w)) return f.atomsReachIndexed(xs);
    for (xs) |x| {
        // Each comparison made is work (kernel §8); past the budget it reaches.
        // An old name is a step: it is compared with nothing.
        if (f.isOld(x)) {
            if (f.charge(1)) return true;
            continue;
        }
        if (f.charge(w.len + 1)) return true;
        for (w) |y| if (f.overlap(x, y)) return true;
        const r = f.roots.items[x.root];
        if (r.kind == .answer and x.root != f.skip_answer) for (f.answers.items[r.ent].base.items) |b| {
            if (f.isOld(b)) continue;
            if (f.charge(w.len)) return true;
            for (w) |y| if (f.overlap(b, y)) return true;
        };
    }
    return false;
}

/// `atomsReach` of the write in judgement (`w_ix`): each atom of `xs` is
/// compared only with the atoms of its root and entry, a lookup, since no
/// other can overlap it. The same answer as the scan (research report 145).
fn atomsReachIndexed(f: *Frame, xs: []const Atom) bool {
    for (xs) |x| {
        if (f.isOld(x)) {
            if (f.charge(1)) return true;
            continue;
        }
        if (f.overlapIndexed(x)) return true;
        const r = f.roots.items[x.root];
        if (r.kind == .answer and x.root != f.skip_answer) for (f.answers.items[r.ent].base.items) |b| {
            if (f.isOld(b)) continue;
            if (f.overlapIndexed(b)) return true;
        };
    }
    return false;
}

/// Whether atom `x` overlaps an atom of the write in judgement (`w_ix`):
/// a lookup, and each atom of its group compared (kernel §8). Past the
/// budget it does.
fn overlapIndexed(f: *Frame, x: Atom) bool {
    const g = f.w_ix.group(x.root, x.e);
    // Never more than the scan of the write costs (`atomsReach`).
    if (f.charge(@min(Loc.lookup_units + g.len, f.w_ix.of.len + 1))) return true;
    for (g) |y| if (f.overlap(x, y)) return true;
    return false;
}

/// The atoms of a write grouped by root and entry, and by root (`indexWrite`):
/// two atoms can overlap only at one root and entry (`overlap`).
const WIndex = struct {
    /// The write indexed: its slice, compared by address and length.
    of: []const Atom = &.{},
    on: bool = false,
    sorted: std.ArrayList(Atom) = .empty,
    by_re: std.AutoHashMapUnmanaged([2]u32, [2]u32) = .empty,

    fn group(ix: *const WIndex, root: u32, e: u32) []const Atom {
        const r = ix.by_re.get(.{ root, e }) orelse return &.{};
        return ix.sorted.items[r[0]..r[1]];
    }

    /// The atoms of root `root`: a run of `sorted`, by binary search.
    fn ofRoot(ix: *const WIndex, root: u32) []const Atom {
        const xs = ix.sorted.items;
        const Cmp = struct {
            fn order(r: u32, a: Atom) std.math.Order {
                return std.math.order(r, a.root);
            }
            fn above(r: u32, a: Atom) std.math.Order {
                return if (a.root <= r) .gt else .lt;
            }
        };
        const lo = std.sort.lowerBound(Atom, xs, root, Cmp.order);
        const hi = std.sort.lowerBound(Atom, xs, root, Cmp.above);
        return xs[lo..hi];
    }
};

/// The fewest atoms of a write that `indexWrite` indexes: a smaller write
/// is scanned, as before.
const w_index_min = 32;

/// Index the write `ws` in judgement (`w_ix`), when it has more than
/// `w_index_min` atoms. A write
/// of every field of a record of `n` fields, compared atom by atom with
/// each later read of a field, cost n² (research report 145).
fn indexWrite(f: *Frame, ws: []const Atom) Error!void {
    const ix = &f.w_ix;
    ix.on = false;
    if (ws.len <= w_index_min) return;
    ix.sorted.clearRetainingCapacity();
    ix.by_re.clearRetainingCapacity();
    // The index is not counted apart: it is linear in the write's atoms,
    // each counted where it was made, and each test that reads it costs at
    // most what the scan it replaces cost, so no budget moves toward a
    // limit (research report 145's review).
    try ix.sorted.appendSlice(f.gpa, ws);
    std.mem.sort(Atom, ix.sorted.items, {}, struct {
        fn lt(_: void, a: Atom, b: Atom) bool {
            return a.root < b.root or (a.root == b.root and a.e < b.e);
        }
    }.lt);
    const xs = ix.sorted.items;
    var i: usize = 0;
    while (i < xs.len) {
        var j = i;
        while (j < xs.len and xs[j].root == xs[i].root and xs[j].e == xs[i].e) j += 1;
        try ix.by_re.put(f.gpa, .{ xs[i].root, xs[i].e }, .{ @intCast(i), @intCast(j) });
        i = j;
    }
    ix.of = ws;
    ix.on = true;
}

/// Whether `w` is the write that `w_ix` indexes.
fn wIndexed(f: *const Frame, w: []const Atom) bool {
    const ix = &f.w_ix;
    return ix.on and w.len == ix.of.len and w.ptr == ix.of.ptr;
}

/// An old name, for the write in judgement: the holder has the cells under
/// the name that a write at this point or later gave them, so it does not
/// read the value from before the write. A name that was old before the
/// write is the cells themselves: the holder reads what the write changes.
fn isOld(f: *const Frame, x: Atom) bool {
    if (f.judge_probe and x.ren != none and f.judge_at <= x.ren) return true;
    return x.dead != none and (f.judge_at == none or f.judge_at <= x.dead);
}

/// The time of an operation at `inst`: a read, a write, an escape, or the
/// new name that a call gives. The walk goes in the order that the emitted
/// JavaScript evaluates in (`language.md` §6, *Evaluation order*; the
/// emitter's `orderedExprs`): a callee or a receiver, then the arguments in
/// order; a `case`'s scrutinee, then one arm; a `let`'s bindings in order,
/// then its body. It records each operation after the operands that the
/// operation consumes. So the order of these times is the program's order.
/// An instruction's number is not: lowering numbers the operand of `x ▷ e`
/// before `e`, and a binding before its value (research report 114 §7).
///
/// What one operation records has one time: the records at one instruction
/// with no expression entered between them. A record at another
/// instruction, or after the walk entered an expression, has a later time.
fn timeOf(f: *Frame, inst: u32) u32 {
    if (inst != f.clock_inst or f.entered != f.clock_entered) {
        f.clock += 1;
        f.clock_inst = inst;
        f.clock_entered = f.entered;
    }
    return f.clock;
}

fn placeOfVal(f: *Frame, v: Val) ?PlaceId {
    const n = f.nodes.items[v];
    return switch (n.tag) {
        .none, .outside, .fnref => null,
        .ref, .built, .join, .closure, .unknown => n.place,
        .later => unreachable, // read through `capVal` only
    };
}

/// The part of `v` that step `s` reaches. A part that the walk cannot name
/// is `unknown`: it can hold each cell of `v`.
fn project(f: *Frame, v: Val, s: Step) Error!Val {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none => return v_none,
        // A part of a value outside the frame is outside the frame.
        .outside => return v_outside,
        // A function has no part that the type names: whatever is read of it can hold what it captured.
        .closure => return f.unknownOf(n.place, &.{v}),
        .fnref => return v_outside,
        .ref => {
            // The path is looked up, or made (kernel §8).
            _ = f.charge(Loc.lookup_units);
            const np = (try f.m.loc.pathExtend(n.b, s)) orelse return f.unknownOf(n.place, &.{v});
            const child = f.m.loc.paths.items[np].place;
            if (try f.layoutLen(child) == 0) return v_outside;
            // A part of a list pattern's part is at its position too (kernel §4.4).
            if (n.pos != none) return f.node(.{ .tag = .ref, .place = child, .a = n.a, .b = np, .pos = n.pos });
            return f.refVal(n.a, np);
        },
        .built => {
            if (n.b > scan_parts) return f.builtPart(v, n, s);
            // A scan of the parts is work of its own (kernel §8).
            _ = f.charge(n.b);
            for (0..n.b) |ki| if (f.kids.items[n.a + ki].step == s.word()) return f.kids.items[n.a + ki].val;
            return f.builtAbsent(v, n, s);
        },
        .join => {
            // A join's arms can share values (an arm that is the value of
            // an earlier `case`), so the values of a walk are a DAG. A part
            // of one value at one step is projected once in the frame
            // (`proj_memo`): a value never changes once it is made, so the
            // part is the one a second projection would make, and a chain
            // of `case`s costs its distinct values, not the paths through
            // them (research report 135). The lookup is work (kernel §8).
            if (f.charge(Loc.lookup_units)) return f.unknownOf(n.place, &.{v});
            const key: [2]u32 = .{ v, s.word() };
            if (f.proj_memo.get(key)) |hit| return hit;
            // A part made is a call (kernel §8): a new join, and its arms.
            if (f.tick()) return f.unknownOf(n.place, &.{v});
            const part = try f.projectJoin(v, n, s);
            try f.proj_memo.put(f.gpa, key, part);
            return part;
        },
        .unknown => {
            const pr = (try f.m.loc.proj(n.place, s)) orelse return f.unknownOf(n.place, &.{v});
            if (try f.layoutLen(pr.child) == 0) return v_none;
            return f.node(.{ .tag = .unknown, .place = pr.child, .a = n.a, .b = n.b });
        },
        .later => unreachable, // read through `capVal` only
    }
}

/// The most parts of a construction that `project` scans; one of more parts
/// is indexed by step (`builtPart`).
const scan_parts = 16;

/// `project` of the construction `v` (node `n`) of more than `scan_parts`
/// parts: its first part at step `s`, looked up in an index made once in
/// the frame (`built_parts`), and `v_none` when no part is at `s`, as a
/// scan answers. A scan for each projection cost the square of a record's
/// width: a field read of each field of a record of 3 000 (research report
/// 145). The index costs a lookup for each part, once, and each projection a
/// lookup (kernel §8).
fn builtPart(f: *Frame, v: Val, n: Node, s: Step) Error!Val {
    // The first projection scans, as before: most constructions are
    // projected once. The second costs the scan too, and makes the index;
    // each later one is a lookup. So no projection costs more than the scan
    // did, and a budget never moves toward a limit.
    const made = try f.built_parted.getOrPut(f.gpa, v);
    if (!made.found_existing) {
        made.value_ptr.* = false;
        _ = f.charge(n.b);
        for (0..n.b) |ki| if (f.kids.items[n.a + ki].step == s.word()) return f.kids.items[n.a + ki].val;
        return f.builtAbsent(v, n, s);
    }
    if (!made.value_ptr.*) {
        made.value_ptr.* = true;
        _ = f.charge(n.b);
        for (0..n.b) |ki| {
            const k = f.kids.items[n.a + ki];
            // The first part at a step is the one a scan finds.
            const got = try f.built_parts.getOrPut(f.gpa, .{ v, k.step });
            if (!got.found_existing) got.value_ptr.* = k.val;
        }
    } else _ = f.charge(Loc.lookup_units);
    return f.built_parts.get(.{ v, s.word() }) orelse f.builtAbsent(v, n, s);
}

/// The part of the construction `v` (node `n`) at step `s`, where no part of
/// it is. A construction names every part of its own place that holds a
/// cell (`built`, `recordUpdate`): another constructor's argument, and a
/// field whose value held no object, hold none. A step that its own place
/// does not have is another reading of the value (kernel §3.4: a tuple read
/// as a record through `Js.to`, which is one JavaScript object): the
/// construction says nothing of it, so the part is `unknown` over `v`, never
/// `none` (research report 147). The lookup is work (kernel §8).
fn builtAbsent(f: *Frame, v: Val, n: Node, s: Step) Error!Val {
    _ = f.charge(Loc.lookup_units);
    if (try f.m.loc.proj(n.place, s) == null) return f.unknownOf(n.place, &.{v});
    return v_none;
}

/// `project` of the join `v` (node `n`): the join of its arms' parts.
fn projectJoin(f: *Frame, v: Val, n: Node, s: Step) Error!Val {
    const pr = (try f.m.loc.proj(n.place, s)) orelse return f.unknownOf(n.place, &.{v});
    // Each arm projected is work (kernel §8); past the budget the part is
    // unknown over the value.
    if (f.charge(n.b)) return f.unknownOf(n.place, &.{v});
    const tmp = try f.gpa.alloc(Val, n.b);
    defer f.gpa.free(tmp);
    const ctxs = try f.gpa.alloc(u32, n.b);
    defer f.gpa.free(ctxs);
    for (0..n.b) |i| {
        tmp[i] = try f.project(f.lists.items[n.a + 2 * i], s);
        ctxs[i] = f.lists.items[n.a + 2 * i + 1];
    }
    return f.joinVal(pr.child, tmp, ctxs);
}

// ---- contexts, reads, escapes ---------------------------------------------------------

fn enterArm(f: *Frame, case_inst: u32, arm: u32) Error!u32 {
    const saved = f.cur_ctx;
    try f.ctxs.append(f.gpa, .{ .parent = saved, .case = case_inst, .arm = arm, .depth = f.ctxs.items[saved].depth + 1 });
    f.cur_ctx = @intCast(f.ctxs.items.len - 1);
    return saved;
}

/// Whether two points can be on one run: not in two arms of one `case`.
fn compatible(f: *const Frame, a0: u32, b0: u32) bool {
    var a = a0;
    var b = b0;
    const cs = f.ctxs.items;
    // Each context climbed is work (kernel §8): a pair of a write and a read
    // in two arms of cases nested deep costs their depth. Past the budget the
    // two are compatible.
    var climbed: usize = 0;
    while (cs[a].depth > cs[b].depth) : (climbed += 1) a = cs[a].parent;
    while (cs[b].depth > cs[a].depth) : (climbed += 1) b = cs[b].parent;
    const ok = while (a != b) : (climbed += 2) {
        if (cs[a].parent == cs[b].parent) break cs[a].case != cs[b].case;
        a = cs[a].parent;
        b = cs[b].parent;
    } else true;
    if (f.charge(climbed)) return true;
    return ok;
}

/// All of `v` is read at `point`.
fn readAll(f: *Frame, v: Val, point: u32) Error!void {
    if (v == v_none or v == v_outside) return;
    if (f.nodes.items[v].tag == .fnref) return;
    try f.uses.append(f.gpa, .{ .point = point, .at = f.timeOf(point), .val = try f.cellsNowIn(v), .ctx = f.cur_ctx });
}

/// All of `v` is read at `point` but its records' field slots (a list
/// pattern reads the list, not the fields of its elements; a record pattern
/// reads its fields' slots itself, kernel §11).
fn readNoSlots(f: *Frame, v: Val, point: u32) Error!void {
    if (v == v_none or v == v_outside) return;
    const n = f.nodes.items[v];
    if (n.tag == .fnref) return;
    if (whole(n.tag)) return f.readAll(v, point);
    const es = f.m.loc.layoutEntries(try f.m.loc.layoutOf(n.place));
    // The scan of the layout is work (kernel §8).
    _ = f.charge(Loc.scanUnits(es.len));
    const start: u32 = @intCast(f.lists.items.len);
    var all = true;
    for (es, 0..) |e, k| {
        if (e.kind == .field) {
            all = false;
            continue;
        }
        try f.lists.append(f.gpa, @intCast(k));
    }
    if (all) {
        f.lists.shrinkRetainingCapacity(start);
        return f.readAll(v, point);
    }
    const nmask: u32 = @intCast(f.lists.items.len - start);
    if (nmask == 0) return;
    try f.uses.append(f.gpa, .{ .point = point, .at = f.timeOf(point), .val = try f.cellsNowIn(v), .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = false });
}

/// `v` is read at `point` by a callee whose contract flags are `flags` over the signature layout `sig`.
fn readBy(f: *Frame, v: Val, point: u32, sig: u32, flags: []const u8) Error!void {
    if (v == v_none or v == v_outside) return;
    const n = f.nodes.items[v];
    if (n.tag == .fnref) return;
    if (whole(n.tag)) {
        // A function value: read when the callee reads, calls or keeps it
        // (a contract has the read flag on a function parameter that the body uses).
        // The scan of the flags is work (kernel §8).
        _ = f.charge(Loc.scanUnits(flags.len / 4));
        var any = false;
        for (flags) |x| if (CMod.reads(x)) {
            any = true;
        };
        if (any) try f.readAll(v, point);
        return;
    }
    const own = try f.m.loc.layoutOf(n.place);
    const cov = try f.m.loc.cover(sig, own);
    const start: u32 = @intCast(f.lists.items.len);
    var all = true;
    var any_flag = false;
    // The scan of the flags and of the map is work (kernel §8): a read of a
    // record of thousands of lists costs its layout at each call.
    _ = f.charge(Loc.scanUnits(flags.len / 4) + cov.len);
    for (flags) |x| if (CMod.reads(x)) {
        any_flag = true;
    };
    // A wide entry of `v`'s own layout that holds the cells of locations of
    // the signature below it (`Loc.holes`) is read where they are read (kernel §3.4).
    const extra = try f.holeFlags(sig, own, flags);
    defer f.gpa.free(extra);
    for (cov, 0..) |c, k| {
        const read = if (c == none) true else if (c == Loc.all) any_flag else CMod.reads(flags[c]);
        if (read or (extra.len != 0 and CMod.reads(extra[k]))) try f.lists.append(f.gpa, @intCast(k)) else all = false;
    }
    const nmask: u32 = @intCast(f.lists.items.len - start);
    if (nmask == 0) return;
    try f.uses.append(f.gpa, .{ .point = point, .at = f.timeOf(point), .val = try f.cellsNowIn(v), .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = all });
}

fn useReaches(f: *Frame, u: Read, ws: []const Atom) Error!bool {
    if (u.all) return f.reach(u.val, ws);
    const n = f.nodes.items[u.val];
    for (0..u.nmask) |i| {
        const k = f.lists.items[u.mask + i];
        // A part of a root: its atoms at `k` are read where they are, not
        // copied (`refReaches`), so a read of a name that holds every older
        // name of a chain of writes costs a step when they are all old.
        if (n.tag == .ref and n.pos == none) {
            if (try f.refReaches(n.a, n.b, k, ws)) return true;
            continue;
        }
        f.scratch.clearRetainingCapacity();
        _ = try f.leaves(u.val, k, &f.scratch);
        if (f.atomsReach(f.scratch.items, ws)) return true;
    }
    return false;
}

/// Whether the atoms that `leaves` finds for the part `(root, path)` at
/// entry `k` of its place's layout can be a cell of `w`: the same atoms as
/// `leavesOwnWalk` of a `ref` and `rootLeaves` make, tested where they are.
/// The `via` that a copy sets is not read by `atomsReach`.
fn refReaches(f: *Frame, root: u32, path: u32, k: u32, w: []const Atom) Error!bool {
    // The step that `leaves` counts, and the entry it maps (kernel §8).
    if (f.tick() or f.charge(1)) return true;
    const re = f.m.loc.paths.items[path].to_root[k];
    // A location the root's layout does not name: it can hold any cell of
    // the root, so it reaches (research report 148).
    if (re == none) return true;
    const r = f.roots.items[root];
    switch (r.kind) {
        .outside => return false,
        .param, .capture, .answer => return f.atomsReach(&.{.{ .root = root, .path = path, .e = re }}, w),
        .fresh => return f.atomsReach(&.{.{ .root = root, .path = r.path, .e = 0 }}, w),
        .local => {
            const ent = f.rents.items[r.ent + re];
            const own_path = if (ent.twice) r.path else path;
            if (ent.hasOwn() and f.atomsReach(&.{.{ .root = root, .path = own_path, .e = re }}, w)) return true;
            return switch (ent.kind) {
                .own, .taken => false,
                .version, .derived, .alias => f.runReaches(root, re, ent, w),
            };
        },
    }
}

/// `atomsReach` of the run of entry `re` of root `root`. A run every atom
/// of which is an old name for the write in judgement reaches nothing, and
/// a run never changes once its entry is made, so that is known from the
/// run's lowest `dead` (`RunFact.old`), found once: a step, not a scan.
fn runReaches(f: *Frame, root: u32, re: u32, ent: REntry, w: []const Atom) Error!bool {
    const run = f.atoms.items[ent.start..][0..ent.len];
    if (run.len == 0) return false;
    const rf = try f.runFact(.{ .root = root, .path = 0, .e = re });
    if (rf.old == 0) {
        // A scan of the run, once for each entry (kernel §8).
        _ = f.charge(run.len);
        // `none` is the largest time: a name that is never old.
        var low: u32 = none;
        var never = false;
        for (run) |a| {
            if (a.dead == none) never = true;
            low = @min(low, a.dead);
        }
        rf.old = if (never) 1 else low +| 2;
    }
    if (!f.judge_probe and rf.old != 1 and (f.judge_at == none or f.judge_at <= rf.old - 2)) {
        if (safety and run.len <= 64) for (run) |a| std.debug.assert(f.isOld(a));
        return f.charge(1);
    }
    return f.atomsReach(run, w);
}

fn escape(f: *Frame, v: Val, point: u32) Error!void {
    if (v == v_none or v == v_outside) return;
    try f.readAll(v, point);
    const start: u32 = @intCast(f.atoms.items.len);
    try f.heldLeaves(v, &f.atoms);
    try f.noteEscape(start, point);
}

/// The leaves of `v` that a holder that keeps it can observe (kernel §6
/// rule 3, *A kept closure is observed only through its calls*): every
/// leaf, but of a closure only the leaves of its captures at the locations
/// its contract reaches. A captured function, a contract that casts and a
/// draft are held whole: what a run of them reaches is not settled here.
fn heldLeaves(f: *Frame, v: Val, out: *std.ArrayList(Atom)) Error!void {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .closure => if (try f.closureHeld(v, out)) return,
        .join => {
            // Each arm is work (kernel §8); past the budget, every leaf.
            if (!f.charge(n.b)) {
                for (0..n.b) |ki| try f.heldLeaves(f.lists.items[n.a + 2 * ki], out);
                return;
            }
        },
        // Every other value is held whole.
        .none, .outside, .ref, .fnref, .built, .unknown => {},
        .later => unreachable, // read through `capVal` only
    }
    _ = try f.allLeaves(v, out);
}

/// The leaves of the closure `v`'s captures at the locations its contract
/// reaches, appended to `out`; false, with nothing appended, where the
/// closure is held whole.
fn closureHeld(f: *Frame, v: Val, out: *std.ArrayList(Atom)) Error!bool {
    const m = f.m;
    const code = f.codes.items[f.nodes.items[v].a];
    const lc = code.contract;
    if (m.isDraft(lc) or lc.casts or code.own_params + code.ncaps > lc.arity) return false;
    for (0..code.ncaps) |k| if (lc.fns[code.own_params + k] != null) return false;
    for (0..code.ncaps) |k| {
        const j: u32 = @intCast(code.own_params + k);
        // A writer's handle is no holder the frame loses (kernel §13 item 12).
        if (f.isWriter(code, k)) continue;
        const capv = try f.capVal(code, k);
        const n = lc.off[j + 1] - lc.off[j];
        // The scan of the capture's flags and of the answer's sources is work (kernel §8).
        _ = f.charge(Loc.scanUnits(n));
        for (0..n) |e| {
            var touched = lc.flags[lc.off[j] + e] != 0 or handsOn(lc, j, @intCast(e));
            if (!touched) for (lc.res) |srcs| for (srcs) |s| if (s.kind == .param and s.a == j and s.e == e) {
                touched = true;
            };
            if (!touched) continue;
            _ = try f.argLeaves(capv, lc.layouts[j], @intCast(e), &.{}, false, out);
        }
    }
    return true;
}

/// The atoms `f.atoms[start..]` escape at `point`: they are held by something
/// the walk does not follow, so no later write of them is accepted (`demand`).
fn noteEscape(f: *Frame, start: u32, point: u32) Error!void {
    try f.uniqueTail(&f.atoms, start);
    const n: u32 = @intCast(f.atoms.items.len - start);
    if (n == 0) return;
    try f.markAtoms(f.atoms.items[start..][0..n], flag_e);
    const at: u32 = @intCast(f.esc_atoms.items.len);
    try f.esc_atoms.appendSlice(f.gpa, f.atoms.items[start..]);
    // The answer of a function parameter can hold what the function was
    // handed (`Answer.base`): where the answer escapes, so does that.
    for (start..start + n) |i| {
        const a = f.atoms.items[i];
        const r = f.roots.items[a.root];
        if (r.kind == .answer) {
            try f.esc_atoms.appendSlice(f.gpa, f.answers.items[r.ent].base.items);
            // What an answer was handed grows as the walk goes on: a judgment
            // of `flow` that read it is not one that an equal use repeats.
            f.ctx_floor = 0;
        }
    }
    const len: u32 = @intCast(f.esc_atoms.items.len - at);
    try f.escapes.append(f.gpa, .{ .start = at, .len = len, .point = point, .ctx = f.cur_ctx });
    // An escaped handle has another holder (kernel §13).
    try f.shareAtoms(start, start + n, point);
}

/// Set `flag` on the parameter location that atom `a` is, or was taken
/// from. The run of a `version` or `taken` entry holds atoms of roots made
/// before its own, and their runs hold older ones again. Marking is
/// idempotent and a run never changes once its entry is made, so each entry
/// is marked once for each flag in the frame's walk (`RunFact.marked`), and a
/// chain of `n` writes costs `n` entries over all of its writes, not `n` for
/// each (research report 119 §4.1, report 134). Each entry and each atom of
/// its run is counted where it is put on the work list (kernel §8); past the
/// budget the marking stops, and the declaration gives up.
fn markAtom(f: *Frame, a: Atom, flag: u8) Error!void {
    return f.markAtoms(&.{a}, flag);
}

/// `markAtom` of each of `atoms`, which the caller counted.
fn markAtoms(f: *Frame, atoms: []const Atom, flag: u8) Error!void {
    f.mark_stack.clearRetainingCapacity();
    try f.mark_stack.appendSlice(f.gpa, atoms);
    while (f.mark_stack.pop()) |x| {
        const r = f.roots.items[x.root];
        switch (r.kind) {
            .param, .capture => f.pflags.items[r.ent + x.e] |= flag,
            .local => {
                const ent = f.rents.items[r.ent + x.e];
                switch (ent.kind) {
                    .own, .alias, .derived => continue,
                    .taken, .version => {},
                }
                const rf = try f.runFact(x);
                if (rf.marked & flag == flag) continue;
                rf.marked |= flag;
                if (f.charge(1 + ent.len)) return;
                try f.mark_stack.appendSlice(f.gpa, f.atoms.items[ent.start..][0..ent.len]);
            },
            // The answer of a function parameter escapes: the contract says so,
            // and the caller that knows the function lets what it answers escape.
            .answer => if (flag & flag_e != 0) {
                f.drafts.items[r.index].ans_escapes = true;
            },
            .outside, .fresh => {},
        }
    }
}

/// What the walks of runs know of one entry of `rents`: the flags that
/// `markAtom` set on all of its run, the highest ground of its run plus one
/// (`runGround`; 0 is not known yet), the last visit that reached it, and
/// its lowest `dead` plus two (`runReaches`; 1: an atom of it is never old;
/// 0: not known yet).
const RunFact = struct { marked: u8 = 0, ground: u8 = 0, seen: u32 = 0, old: u32 = 0 };

/// The facts of the entry of a root the frame made that atom `a` is at. A
/// run never changes once its entry is made, so each fact holds for the rest
/// of the walk. The pointer holds until the next call.
fn runFact(f: *Frame, a: Atom) Error!*RunFact {
    const i = f.roots.items[a.root].ent + a.e;
    if (i >= f.run_facts.items.len) try f.run_facts.appendNTimes(f.gpa, .{}, f.rents.items.len - f.run_facts.items.len);
    return &f.run_facts.items[i];
}

/// A new visit of runs: no entry is visited by it yet.
fn newVisit(f: *Frame) void {
    f.visit +%= 1;
    if (f.visit == 0) {
        for (f.run_facts.items) |*x| x.seen = 0;
        f.visit = 1;
    }
}

/// Whether the visit in progress reached atom `a`'s entry before; it has now.
fn visited(f: *Frame, a: Atom) Error!bool {
    const rf = try f.runFact(a);
    if (rf.seen == f.visit) return true;
    rf.seen = f.visit;
    return false;
}

// ---- demands -------------------------------------------------------------------------

const DemandIn = struct {
    point: u32,
    op: Op = .call,
    kind: Facts.DemandKind = .writer,
    callee_inst: u32 = none,
    base_inst: u32 = none,
    loc: u32 = 0,
    /// The operands of the operation, and which one is written.
    others: []const Other = &.{},
    arg: usize = std.math.maxInt(usize),
    /// The callee's entry that is written, in the written operand's signature layout.
    se: u32 = none,
    /// The part below that entry that is written (a function writes a part
    /// of what a type variable stands for), or empty: all of it.
    suffix: []const u64 = &.{},
    draft: u32 = none,
    slot: u32 = 0,
    skip: u32 = none,
    send: bool = false,
    dup: bool = false,
    /// The written location is a list's: a record's field slot among the
    /// atoms (an `unknown` value's, which can be any cell) is no cell of it.
    list_only: bool = false,
};

/// What the operation reads of operand `o` reaches the targets `ws`; `skip`
/// is the written entry of the written operand itself, and `suffix` the
/// written part below it. Another part below the same entry is another
/// operand: a cell at two parts of one value is no `own` cell.
fn otherReaches(f: *Frame, o: Other, ws: []const Atom, skip: u32, suffix: []const u64) Error!bool {
    if (o.v == v_none or o.v == v_outside) return false;
    const n = f.nodes.items[o.v];
    if (n.tag == .fnref) return false;
    if (o.self_only) {
        const place = f.placeOfVal(o.v) orelse return false;
        if (whole(n.tag)) return f.reach(o.v, ws);
        const self = try f.m.selfLoc(place);
        const pes = f.m.loc.layoutEntries(try f.m.loc.layoutOf(place));
        // The scan of the layout is work (kernel §8).
        if (f.charge(Loc.scanUnits(pes.len))) return true;
        for (pes, 0..) |e, k| if (e.loc == self) {
            f.scratch.clearRetainingCapacity();
            _ = try f.leaves(o.v, @intCast(k), &f.scratch);
            if (f.atomsReach(f.scratch.items, ws)) return true;
        };
        return false;
    }
    if (o.sig == none or whole(n.tag)) {
        if (skip != none) return false;
        return f.reach(o.v, ws);
    }
    const own_layout = try f.m.loc.layoutOf(n.place);
    const cov = try f.m.loc.cover(o.sig, own_layout);
    // The scans of the flags, of the layout and of the map are work (kernel §8).
    if (f.charge(Loc.scanUnits(o.flags.len / 4) + 2 * cov.len)) return true;
    var any_flag = false;
    for (o.flags) |x| if (x != 0) {
        any_flag = true;
    };
    // The written part's location, when the operand has it.
    var want: ?u32 = null;
    if (skip != none and skip < Loc.all and suffix.len != 0) {
        want = f.m.loc.layoutEntries(o.sig)[skip].loc;
        for (suffix) |l| {
            want = f.m.loc.find(want.?, l);
            if (want == null) break;
        }
        if (want) |wl| {
            var found = false;
            for (f.m.loc.layoutEntries(own_layout), 0..) |oe, k| if (oe.loc == wl and cov[k] == skip) {
                found = true;
            };
            if (!found) want = null;
        }
    }
    // The kinds of cell the targets are (kernel §11). A location the callee
    // only answers (`flag_a`) is another operand where its cells can be the
    // targets: a field slot is no list, and the slots of two fields are two
    // cells (`canShare`), so an answered location of another kind is not
    // looked at. A target of no layout, or more kinds than the set holds,
    // can be any cell. A location the callee reads is looked at whatever its
    // kind, as it was before answers had a flag.
    var wes: [16]Loc.Entry = undefined;
    var nwes: usize = 0;
    const any_kind = for (ws) |x| {
        const xr = f.roots.items[x.root];
        if (xr.kind == .outside or xr.kind == .fresh) break true;
        const xes = f.m.loc.layoutEntries(xr.layout);
        if (x.e >= xes.len) break true;
        const xe = xes[x.e];
        const seen = for (wes[0..nwes]) |we| {
            if (we.kind == xe.kind and (xe.kind != .field or f.m.loc.loc_label.items[we.loc] == f.m.loc.loc_label.items[xe.loc])) break true;
        } else false;
        if (seen) continue;
        if (nwes == wes.len) break true;
        wes[nwes] = xe;
        nwes += 1;
    } else false;
    const own_es = f.m.loc.layoutEntries(own_layout);
    // A wide entry of the operand's own layout that holds the cells of
    // locations of the signature below it (`Loc.holes`) has their flags too (kernel §3.4).
    const extra = try f.holeFlags(o.sig, own_layout, o.flags);
    defer f.gpa.free(extra);
    // The written location is below a wide entry of the operand's own
    // layout: that entry is the written cells, and it holds the cells of each
    // other location of the signature below it too. Another of those that the
    // callee reads or answers is the written cells, and no rule makes the two
    // apart: the operand cannot say which of its cells are at which (kernel
    // §3.4, §5 test 2).
    if (skip != none and skip < Loc.all) if (try f.m.loc.holes(o.sig, own_layout)) |h| {
        const k0 = h.above[skip];
        if (k0 != none) {
            _ = f.charge(Loc.scanUnits(h.above.len));
            for (h.above, 0..) |k, j| if (j != skip and k == k0 and o.flags[j] != 0) return true;
            const c0 = cov[k0];
            if (c0 == Loc.all and any_flag) return true;
            if (c0 < Loc.all and c0 != skip and o.flags[c0] != 0) return true;
        }
    };
    // The scan of the targets is work, and so is each test of an entry against their kinds (kernel §8).
    if (f.charge(ws.len)) return true;
    // Whether the operand holds each cell once, asked at the first entry
    // the map cannot place (below).
    var apart_value: ?bool = null;
    for (cov, 0..) |c, k| {
        const more: u8 = if (extra.len != 0) extra[k] else 0;
        if (!any_kind and c < Loc.all and (o.flags[c] | more) == flag_a) {
            if (f.charge(nwes)) return true;
            const meets = for (wes[0..nwes]) |we| {
                if (canShare(f.m, own_es[k], we)) break true;
            } else false;
            if (!meets) continue;
        }
        if (c == skip and skip != none) {
            const wl = want orelse continue;
            if (f.m.loc.layoutEntries(own_layout)[k].loc == wl) continue;
        }
        if (c == Loc.all) {
            // An entry the map cannot place (the deep level of a cycle whose
            // region the signature reads with a type variable, `Loc.cycleWider`)
            // is at every location of the signature: the written one, and each
            // other that the callee reads or answers. It is the written entry
            // itself only where no other location has a flag; else it is
            // another place of the operand too, and its cells are tested as
            // one (research report 148: a callee over `T a` wrote the entry
            // level's list and read the deep level's, and the caller's
            // `T xs [ T xs [] ]` passed). Two locations of the signature hold
            // two sets of cells where the operand holds each cell once
            // (`valueApart`, the apart-arguments rule of kernel §4.4): its
            // cells at the entry are then each at one of them, and the
            // callee's write of one is no read of another. Where it does not,
            // the entry's cells are tested against the written ones.
            if (!any_flag) continue;
            if (skip != none) {
                const other = for (o.flags, 0..) |x, j| {
                    if (j != skip and x != 0) break true;
                } else false;
                if (!other) continue;
                if (apart_value == null) apart_value = try f.valueApart(o.v, 0);
            }
        } else if (c != none and (o.flags[c] | more) == 0) continue;
        f.scratch.clearRetainingCapacity();
        const dup_k = try f.leaves(o.v, @intCast(k), &f.scratch);
        // A summary entry that holds one cell at two of its places is no two sets.
        if (c == Loc.all and skip != none and apart_value.? and !dup_k) continue;
        if (skip != none and n.tag == .ref) {
            // Another location of the written operand itself, which is a part
            // of one root N: two locations of it are two places of N, so they
            // hold two sets of cells when N holds each cell once (`linear`),
            // though one atom of the frame can name both (the entry level and
            // the deep level of a part of a recursive value). A parameter is
            // so by the apart-arguments rule (kernel §4.4); a root the frame
            // made says so itself; the answer of a function parameter can
            // hold one cell at two places, and says nothing. A location whose
            // parts are not apart (`REntry.twice`) is no two sets.
            const apart = switch (f.roots.items[n.a].kind) {
                .local => f.isLinear(n.a),
                .param, .capture => true,
                .answer, .fresh, .outside => false,
            };
            // Each pair compared is work of its own (kernel §8); past the
            // budget another place reaches.
            if (f.charge(f.scratch.items.len * ws.len)) return true;
            for (f.scratch.items) |x| for (ws) |w| {
                if (!f.overlap(x, w)) continue;
                if (apart and !f.twiceAt(x)) continue;
                return true;
            };
            continue;
        }
        if (f.atomsReach(f.scratch.items, ws)) return true;
    }
    return false;
}

/// Whether atom `a` names a record's field slot (kernel §11).
fn isSlotAtom(f: *const Frame, a: Atom) bool {
    const r = f.roots.items[a.root];
    if (r.kind == .outside or r.kind == .fresh) return false;
    const es = f.m.loc.layoutEntries(r.layout);
    return a.e < es.len and es[a.e].kind == .field;
}

/// Judge a write of the atoms `f.atoms[w..]`: what can be decided now is; the
/// reads after it are judged when the frame ends (`finishDemands`).
fn demand(f: *Frame, w: u32, in: DemandIn) Error!void {
    // A write of a new name is a write of the cells' old names too: the
    // leaves of a `version` location have them.
    try f.uniqueTail(&f.atoms, w);
    if (in.list_only) {
        // A list write writes list cells: a field slot is another kind (kernel §11).
        var k: usize = w;
        for (f.atoms.items[w..]) |a| {
            if (f.isSlotAtom(a)) continue;
            f.atoms.items[k] = a;
            k += 1;
        }
        f.atoms.shrinkRetainingCapacity(k);
    }
    const wn: u32 = @intCast(f.atoms.items.len - w);
    var token_inst = in.point;
    if (in.op == .call and in.callee_inst != none) token_inst = in.callee_inst;
    if (f.chain_root != none and in.op != .supply) token_inst = f.chain_root;
    var d: Demand = .{
        .point = in.point,
        .at = f.timeOf(in.point),
        .token = f.m.tokens[token_inst],
        .ctx = f.cur_ctx,
        .op = in.op,
        .kind = in.kind,
        .w = w,
        .wn = wn,
        .callee_inst = in.callee_inst,
        .base_inst = in.base_inst,
        .loc = in.loc,
        .draft = in.draft,
        .slot = in.slot,
        .skip = in.skip,
        .send = in.send,
    };
    if (f.chain_root != none and in.op == .call) {
        d.op = .construction;
        d.kind = .construction;
        d.point = f.chain_root;
    }
    // One function can reach one supply by two ways (a fold hands a function
    // its argument and its own answer): the same demand is one demand.
    if (in.op == .call and in.kind == .callsite) {
        var i = f.demands.items.len;
        while (i > 0) {
            i -= 1;
            const d0 = f.demands.items[i];
            if (d0.point != d.point) break;
            if (d0.op != d.op or d0.kind != d.kind or d0.loc != d.loc or d0.wn != wn or d0.base_inst != d.base_inst or d0.ctx != d.ctx) continue;
            const same = for (f.atoms.items[d0.w..][0..wn], f.atoms.items[w..][0..wn]) |x, y| {
                if (!atomEql(x, y)) break false;
            } else true;
            if (!same) continue;
            f.atoms.shrinkRetainingCapacity(w);
            return;
        }
    }
    // A record's write: an update, or a write whose cells are field slots
    // and no list (a write of a type variable's location can hold both, and
    // is a list's where it holds a list).
    var slots = false;
    var lists = false;
    for (f.atoms.items[w..][0..wn]) |a| {
        const rk = f.roots.items[a.root].kind;
        if (f.isSlotAtom(a)) slots = true else if (rk != .outside and rk != .fresh) lists = true;
    }
    d.record = in.op == .update or (slots and !lists);
    // The permission (kernel §5, test 1): a cell outside the frame, a
    // capture and the answer of a function parameter are never `own`.
    for (0..wn) |i| {
        const a = f.atoms.items[w + i];
        switch (f.roots.items[a.root].kind) {
            .outside => d.refused = .unknown,
            // The contents of a captured cell are written as a parameter's
            // are: each holder that runs the code judges the write against
            // its own holders (kernel §13 item 11).
            .capture => if (!try f.captureContents(a)) {
                d.refused = .captured;
            },
            .answer => if (in.op != .supply) {
                d.refused = .call;
            },
            .param, .local, .fresh => {},
        }
        if (d.refused != null) break;
    }
    if (d.refused == null and in.dup) d.refused = .element;
    // The tests below compare the write with other atoms, each with its own
    // root and entry: a wide write is indexed (`indexWrite`).
    if (d.refused == null) try f.indexWrite(f.atoms.items[w..][0..wn]);
    defer f.w_ix.on = false;
    if (d.refused == null) {
        f.judge_ctx = f.cur_ctx;
        f.judge_at = d.at;
        for (in.others, 0..) |o, k| {
            if (try f.otherReaches(o, f.atoms.items[w..][0..wn], if (k == in.arg) in.se else none, if (k == in.arg) in.suffix else &.{})) {
                d.refused = .disjoint;
                break;
            }
        }
        f.judge_ctx = none;
        f.judge_at = none;
    }
    // Each escape the test passes over is work too (kernel §8).
    if (d.refused == null and f.charge(f.escapes.items.len)) {
        d.refused = .limit;
        d.detail = "the walk of this declaration gave up";
    }
    if (d.refused == null) {
        for (f.escapes.items) |e| {
            if (!f.compatible(e.ctx, f.cur_ctx)) continue;
            // Each pair of a write and an escape is a step (kernel §8).
            if (f.tick()) {
                d.refused = .limit;
                d.detail = "the walk of this declaration gave up";
                break;
            }
            if (f.overlapWrite(f.esc_atoms.items[e.start..][0..e.len], f.atoms.items[w..][0..wn])) {
                d.refused = .escaped;
                break;
            }
        }
    }
    // The contract asks the caller for what the body writes of a parameter.
    if (in.op != .supply) try f.markAtoms(f.atoms.items[w..][0..wn], flag_w);
    // A write of a cell that a function parameter was handed before: a function that keeps it reads the edit.
    // Each answer compared is work (kernel §8).
    if (in.op != .supply and wn != 0 and !f.charge(f.answers.items.len)) for (f.answers.items) |an| {
        if (f.overlapWrite(an.base.items, f.atoms.items[w..][0..wn])) f.drafts.items[an.di].rewrites = true;
    };
    try f.demands.append(f.gpa, d);
}

/// The row of the lowering channel that reads `u` before the stores of the
/// accepted update `d` (kernel §11, *A read of a written field, read
/// first*), or null where no rule places it there. The read is a chain of
/// field reads from a parameter, which is bound before any expression of
/// the body runs; and the update runs on every path that reaches the read,
/// so a temporary bound just before its stores is in scope at the read
/// and holds what the read reads in the copying program.
fn hoistRow(f: *Frame, d: Demand, u: Read) Error!?OwnHoists.Read {
    const bir = f.m.bir;
    if (u.point >= bir.insts.len or d.point >= bir.insts.len) return null;
    if (bir.instTag(@fromBackingInt(u.point)) != .field_access) return null;
    if (bir.instTag(@fromBackingInt(d.point)) != .record_update) return null;
    var x: Inst.Index = @fromBackingInt(u.point);
    var len: u32 = 0;
    while (bir.instTag(x) == .field_access) : (len += 1) x = @fromBackingInt(@intCast(bir.instData(x).lhs));
    if (bir.instTag(x) != .local) return null;
    const local = bir.instData(x).lhs;
    if (f.d.locals_start + local >= bir.locals.len) return null;
    if (bir.locals[f.d.locals_start + local].kind != .param) return null;
    if (!try f.runsBefore(d.point, u.point)) return null;
    return .{ .decl = f.decl, .demand = d.point, .inst = u.point, .holder = local, .path_len = len, .placement = d.point, .phase = 1 };
}

/// The rows of one chain of field reads stand apart (kernel §11 item 10):
/// where one read of the rows is a part of another's chain (`p.a` of
/// `p.a.f`), the lowering would bind each where its own update is, and the
/// longer read would stand for the shorter one's temporary at a later
/// update, after the first one's stores. No row then holds for the two:
/// each update that carries one is refused, as its read refused it before.
/// Research report 153 §9: `q = { p | a = … }`, `r = { (p.a) | f = 77 }`,
/// then `p.a.f`.
fn hoistsApart(f: *Frame) Error!void {
    const bir = f.m.bir;
    var reads: std.ArrayList(u32) = .empty;
    defer reads.deinit(f.gpa);
    for (f.demands.items) |d| if (d.refused == null) for (d.hoists) |r| try reads.append(f.gpa, r.inst);
    if (reads.items.len < 2) return;
    // The reads of a clash: each read with a part of its chain among the
    // reads, and that part.
    var clash: std.ArrayList(u32) = .empty;
    defer clash.deinit(f.gpa);
    for (reads.items) |ri| {
        var x: Inst.Index = @fromBackingInt(@intCast(bir.instData(@fromBackingInt(ri)).lhs));
        while (bir.instTag(x) == .field_access) : (x = @fromBackingInt(@intCast(bir.instData(x).lhs))) {
            // Each read of the chain is work (kernel §8); past the budget no row stands.
            if (f.charge(1)) {
                for (f.demands.items) |*d| if (d.refused == null and d.hoists.len != 0) {
                    d.refused = .limit;
                    d.detail = "the walk of this declaration gave up";
                    d.hoists = &.{};
                };
                return;
            }
            if (std.mem.indexOfScalar(u32, reads.items, x.int()) == null) continue;
            try clash.appendSlice(f.gpa, &.{ ri, x.int() });
        }
    }
    if (clash.items.len == 0) return;
    for (f.demands.items) |*d| {
        if (d.refused != null) continue;
        for (d.hoists) |r| if (std.mem.indexOfScalar(u32, clash.items, r.inst) != null) {
            d.refused = .later_use;
            d.detail = try f.m.useText(f, r.inst);
            d.hoists = &.{};
            break;
        };
    }
}
/// `r`, and before it, with a temporary bound where `w` runs in scope at
/// `r`: below the two's nearest common instruction, `w` is in a part that
/// is evaluated whenever that instruction is (a call's callee or argument,
/// a construction's part, an update's base or value, a field read's
/// record, a `case`'s scrutinee, a `let`'s definition), with no `let` of
/// its own between (a block of its own is a scope of its own), and that part comes
/// before the one that holds `r`. A `case`'s arm, a lambda, markup (whose
/// holes a lowering can evaluate where it renders), and an argument of a
/// callee that the lowering can short-circuit (`&&`, `||`) are not.
fn runsBefore(f: *Frame, w: u32, r: u32) Error!bool {
    const m = f.m;
    const bir = m.bir;
    if (f.body_root == none) return false;
    if (!f.parents_made) {
        f.parents_made = true;
        f.parents = try f.gpa.alloc(u32, bir.insts.len);
        @memset(f.parents, none);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(f.gpa);
        var kids: std.ArrayList(Inst.Index) = .empty;
        defer kids.deinit(f.gpa);
        try stack.append(f.gpa, f.body_root);
        while (stack.pop()) |n| {
            // Each instruction is work (kernel §8); past the budget no read is placed.
            if (f.charge(1)) return false;
            const tag = bir.instTag(@fromBackingInt(n));
            // A lambda's body is another frame's.
            if (tag == .lambda) continue;
            kids.clearRetainingCapacity();
            try bir.operands(f.gpa, @fromBackingInt(n), &kids);
            for (kids.items) |k| {
                if (k.int() < f.parents.len) f.parents[k.int()] = n;
                try stack.append(f.gpa, k.int());
            }
        }
    }
    // The ancestors of `w`, up to the body.
    var up: std.ArrayList(u32) = .empty;
    defer up.deinit(f.gpa);
    var x = w;
    while (true) {
        try up.append(f.gpa, x);
        if (x == f.body_root) break;
        if (x >= f.parents.len or f.parents[x] == none) return false;
        x = f.parents[x];
    }
    // The nearest ancestor of `r` that is one of them, and the part of it that holds `r`.
    var r_part: u32 = none;
    x = r;
    const lca = while (true) {
        if (std.mem.indexOfScalar(u32, up.items, x) != null) break x;
        if (x == f.body_root) return false;
        if (x >= f.parents.len or f.parents[x] == none) return false;
        const p = f.parents[x];
        // A hole of markup can be evaluated where the markup renders.
        if (bir.instTag(@fromBackingInt(p)) == .markup) return false;
        r_part = x;
        x = p;
    };
    if (lca == w or r_part == none) return false;
    // `w`'s path up to the common instruction: every step runs whenever its parent does.
    const at = std.mem.indexOfScalar(u32, up.items, lca).?;
    for (up.items[0..at], 0..) |child, i| {
        const parent = up.items[i + 1];
        if (parent != lca and bir.instTag(@fromBackingInt(parent)) == .let) return false;
        if (!try f.alwaysRuns(parent, child)) return false;
    }
    const w_part = up.items[at - 1];
    var kids: std.ArrayList(Inst.Index) = .empty;
    defer kids.deinit(f.gpa);
    try bir.operands(f.gpa, @fromBackingInt(lca), &kids);
    var wi: usize = none;
    var ri: usize = none;
    for (kids.items, 0..) |k, i| {
        if (k.int() == w_part and wi == none) wi = i;
        if (k.int() == r_part and ri == none) ri = i;
    }
    return wi != none and ri != none and wi < ri;
}

/// Whether the part `child` of `parent` is evaluated whenever `parent` is.
fn alwaysRuns(f: *Frame, parent: u32, child: u32) Error!bool {
    const bir = f.m.bir;
    const p: Inst.Index = @fromBackingInt(parent);
    const d = bir.instData(p);
    return switch (bir.instTag(p)) {
        .field_access, .tuple_index, .@"try", .let_stmt, .let_pattern, .tuple, .list, .record, .record_update, .interp, .method_call, .let => true,
        // A local function's body runs where it is called.
        .let_def => blk: {
            const def = bir.extraData(@fromBackingInt(@intCast(d.lhs)), Bir.LetDef);
            break :blk def.params_start == def.params_end and child == d.rhs;
        },
        .case => child == d.lhs,
        .call => blk: {
            if (child == d.lhs) break :blk true;
            const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index);
            if (args.len != 0 and args[0].int() == child) break :blk true;
            // A later argument of a declaration of this module: no lowering
            // short-circuits it (`&&` and `||` are `Basics`', of core).
            break :blk bir.instTag(@fromBackingInt(@intCast(d.lhs))) == .top and !f.m.in.isCore(f.m.in.module);
        },
        else => false,
    };
}

const Ground = enum(u8) { fresh, call, param };

/// What a line's acceptance rests on (kernel §5.2): the highest ground of
/// atom `a` and of every atom of the runs below it.
fn groundOf(f: *Frame, a: Atom) Error!Ground {
    const g = ownGround(f, a);
    const ent = f.runOf(a) orelse return g;
    return maxGround(g, try f.runGround(a, ent));
}

/// The ground of atom `a` itself, without the run below it.
fn ownGround(f: *const Frame, a: Atom) Ground {
    const r = f.roots.items[a.root];
    // A cell read through a call's result rests on the callee's contract.
    const via: Ground = if (a.via != none and f.roots.items[a.via].call) .call else .fresh;
    return switch (r.kind) {
        .param, .capture => .param,
        .fresh => .call,
        .local => if (r.call) .call else via,
        // Refused before a ground is asked for.
        .outside, .answer => via,
    };
}

fn maxGround(x: Ground, y: Ground) Ground {
    return if (@backingInt(y) > @backingInt(x)) y else x;
}

/// The entry of a `version` or `taken` location that atom `a` names: one whose
/// run holds older atoms. Null for every other atom.
fn runOf(f: *const Frame, a: Atom) ?REntry {
    const r = f.roots.items[a.root];
    if (r.kind != .local) return null;
    const ent = f.rents.items[r.ent + a.e];
    return switch (ent.kind) {
        .own, .alias, .derived => null,
        .taken, .version => ent,
    };
}

/// The highest ground of the run of entry `ent` (atom `a`'s) and of the runs
/// below it, kept for the entry (`RunFact.ground`): a run never changes once its
/// entry is made, so each entry's run is walked once in the frame, and a
/// chain of `n` writes costs `n` entries over all of its lines (report 134).
/// Each entry and atom is counted (kernel §8); past the budget the walk stops
/// and every line is refused anyway (`finishDemands`).
fn runGround(f: *Frame, a: Atom, ent: REntry) Error!Ground {
    const known = (try f.runFact(a)).ground;
    if (known != 0) return @fromBackingInt(@intCast(known - 1));
    f.newVisit();
    _ = try f.visited(a);
    var g: Ground = .fresh;
    f.mark_stack.clearRetainingCapacity();
    if (f.charge(1 + ent.len)) return .param;
    try f.mark_stack.appendSlice(f.gpa, f.atoms.items[ent.start..][0..ent.len]);
    while (f.mark_stack.pop()) |x| {
        g = maxGround(g, ownGround(f, x));
        const below = f.runOf(x) orelse continue;
        const kx = (try f.runFact(x)).ground;
        if (kx != 0) {
            g = maxGround(g, @fromBackingInt(@intCast(kx - 1)));
            continue;
        }
        if (try f.visited(x)) continue;
        if (f.charge(1 + below.len)) return .param;
        try f.mark_stack.appendSlice(f.gpa, f.atoms.items[below.start..][0..below.len]);
    }
    (try f.runFact(a)).ground = @backingInt(g) + 1;
    return g;
}

/// The reads after each write, and the report lines.
fn finishDemands(f: *Frame) Error!void {
    for (f.demands.items) |*d| {
        const ws = f.atoms.items[d.w..][0..d.wn];
        // A walk that gave up, or a declaration past its steps, accepts
        // nothing (kernel §3.3, §8).
        if ((f.failed or f.m.steps_over) and d.refused == null) {
            d.refused = .limit;
            d.detail = "the walk of this declaration gave up";
        }
        if (d.refused == null) {
            f.skip_answer = d.skip;
            f.judge_ctx = d.ctx;
            f.judge_at = d.at;
            try f.indexWrite(ws);
            defer f.w_ix.on = false;
            // Each read the test passes over is work too (kernel §8).
            if (f.charge(f.uses.items.len)) {
                d.refused = .limit;
                d.detail = "the walk of this declaration gave up";
            }
            // The later reads that the lowering reads first (kernel §11,
            // *A read of a written field, read first*): kept only where the
            // update is accepted.
            var hoists: std.ArrayList(OwnHoists.Read) = .empty;
            if (d.refused == null) for (f.uses.items) |u| {
                // A read at a later time: the walk goes in the program's order (`timeOf`).
                if (u.at <= d.at) continue;
                if (!f.compatible(u.ctx, d.ctx)) continue;
                // Each pair of a write and a later read is a step (kernel §8).
                if (f.tick()) {
                    d.refused = .limit;
                    d.detail = "the walk of this declaration gave up";
                    break;
                }
                if (try f.useReaches(u, ws)) {
                    if (d.op == .update) if (try f.hoistRow(d.*, u)) |row| {
                        try hoists.append(f.gpa, row);
                        continue;
                    };
                    d.refused = .later_use;
                    d.detail = try f.m.useText(f, u.point);
                    break;
                }
            };
            if (d.refused == null) d.hoists = hoists.items;
            f.skip_answer = none;
            f.judge_ctx = none;
            f.judge_at = none;
        }
    }
    try f.hoistsApart();
    for (f.demands.items) |*d| {
        const ws = f.atoms.items[d.w..][0..d.wn];
        if (d.op == .supply) {
            if (d.refused != null and d.draft != none) f.drafts.items[d.draft].free[d.slot] = false;
            if (!d.send) continue;
            // A send asks nothing of the sender (kernel §6.13): the message
            // is never `update`'s own, so no write rests on the sender
            // giving it up, and what the sender hands the runtime escapes
            // where it is handed (rule 2, `defaultParams`). The test above
            // says only whether the function is handed the message `free`.
            // The line is accepted, on the entry rule where the cells are
            // not the sender's own; a walk that gave up accepts nothing.
            if (d.refused) |cause| if (cause != .limit) {
                var line = d.*;
                line.refused = null;
                line.detail = "";
                try f.m.addLine(f, line, .entry);
                continue;
            };
        }
        var g: Ground = .fresh;
        for (ws) |a| {
            const x = try f.groundOf(a);
            if (@backingInt(x) > @backingInt(g)) g = x;
        }
        const ground: Facts.Verdict.Accepted = switch (g) {
            .fresh => .fresh,
            .call => .call,
            .param => if (f.is_lambda) .callback_param else .param,
        };
        try f.m.addLine(f, d.*, ground);
    }
}

// ---- patterns ------------------------------------------------------------------------

// ---- the two positions whose tags are a closed set ----------------------------------------
//
// A pattern holds a pattern tag, and a binding of a `let` holds one of three.
// Anything else in either position is not a program the lowering makes: the
// walk gives up on the declaration (kernel §1). `patTag` and `letTag` are
// the only switches over `Bir.Inst.Tag` that name every tag for these two
// positions, so a new tag compiles only once each is placed.

const PatTag = enum { wild, variable, ctor, int, char, string, unit, tuple, list, spread, record, as, not_a_pattern };

fn patTag(tag: Inst.Tag) PatTag {
    return switch (tag) {
        .pat_wild => .wild,
        .pat_var => .variable,
        .pat_ctor => .ctor,
        .pat_int => .int,
        .pat_char => .char,
        .pat_string => .string,
        .pat_unit => .unit,
        .pat_tuple => .tuple,
        .pat_list => .list,
        .pat_spread => .spread,
        .pat_record => .record,
        .pat_as => .as,
        // Not a pattern: a reference, a type, a schema plan, a literal, an
        // expression, a binding, a branch or the placeholder.
        .local, .top, .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_value, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .@"error" => .not_a_pattern,
    };
}

const LetTag = enum { def, pattern, stmt, not_a_binding };

fn letTag(tag: Inst.Tag) LetTag {
    return switch (tag) {
        .let_def => .def,
        .let_pattern => .pattern,
        .let_stmt => .stmt,
        // Not a binding of a `let`.
        .local, .top, .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_value, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => .not_a_binding,
    };
}

fn bindLocal(f: *Frame, local: u32, v: Val) void {
    const l = f.d.locals_start + local;
    f.m.lv[l] = v;
    f.m.lframe[l] = f.id;
}

fn bindPattern(f: *Frame, pat: u32, v: Val) Error!void {
    // Each node of a pattern is work (kernel §8). Past the budget the
    // pattern is still bound, each node once: no local is read unbound.
    _ = f.charge(1);
    const m = f.m;
    const data = m.datas[pat];
    switch (patTag(m.tags[pat])) {
        .variable => f.bindLocal(data.lhs, v),
        .as => {
            f.bindLocal(data.rhs, v);
            try f.bindPattern(data.lhs, v);
        },
        .tuple => for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index), 0..) |p, k| {
            try f.bindPattern(p.int(), try f.project(v, .{ .kind = .index, .payload = @intCast(k) }));
        },
        .ctor => {
            const args = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            if (args.len == 0) return;
            const info = m.ctorInfo(data.lhs);
            if (m.isRecordAliasCtor(data.lhs)) {
                // A record alias's constructor pattern is a record pattern
                // (backend.md §4): argument `k` is the field that the alias
                // writes `k`-th, read out of its slot where the pattern
                // matches (kernel §11.4). By its constructor's row it named
                // a step that a record does not have, and bound nothing
                // (research report 147).
                for (args, 0..) |p, k| {
                    const s = m.recordAliasStep(data.lhs, @intCast(k)) orelse {
                        // No field for the argument: no claim, and all of `v`.
                        try f.readAll(v, pat);
                        try f.bindPattern(p.int(), try f.unknownOf(try m.placeOfInst(p.int()), &.{v}));
                        continue;
                    };
                    if (m.tags[p.int()] != .pat_wild) try f.readSlots(v, &.{@as(u32, s.payload)}, pat);
                    try f.bindPattern(p.int(), try f.project(v, s));
                }
                return;
            }
            // Where the value holds each cell once, each argument is a part of
            // one match at its own position: apart from the others, though a
            // recursive type's two children read one deep level (kernel §4.4,
            // *The parts of a constructor pattern are apart*). A value that is
            // a part of a list pattern's match keeps that match: its parts
            // are apart from the list's other parts by it.
            const keeps = v != v_none and v != v_outside and f.nodes.items[v].pos != none;
            const match = if (info != null and args.len > 1 and !keeps) try f.listParts(v, args.len) else none;
            for (args, 0..) |p, k| {
                // A constructor that the walk has no row for: its argument can be any part of `v`.
                const part = if (info) |ci| try f.project(v, try m.ctorStep(ci.ordinal, @intCast(k))) else try f.unknownOf(try m.placeOfInst(p.int()), &.{v});
                const at = if (match != none) try f.atPosition(part, match, k) else part;
                try f.bindPattern(p.int(), if (v == v_none) v_none else at);
            }
        },
        .list => {
            const ps = m.bir.extraSlice(Bir.inlineRange(data), Inst.Index);
            // Where the list holds each cell once, each part is at a position
            // of one match: apart from the others (kernel §4.4).
            const match = try f.listParts(v, ps.len);
            for (ps, 0..) |p, k| {
                // The rest of a list pattern is a view of the list: the same storage, the same elements.
                const spread = patTag(m.tags[p.int()]) == .spread;
                const part = if (spread) v else try f.project(v, Step.elem);
                const at = if (match != none) try f.atPosition(part, match, k) else part;
                if (spread) try f.bindPattern(m.datas[p.int()].lhs, at) else try f.bindPattern(p.int(), at);
            }
        },
        .record => for (m.bir.extraSlice(Bir.inlineRange(data), u32)) |local| {
            const name = m.bir.locals[f.d.locals_start + local].name;
            // A field is read out of its record's slot where the pattern matches (kernel §11).
            if (name != .none) try f.readSlots(v, &.{@intCast(m.fieldRank(name))}, pat);
            const part = if (name == .none) try f.unknownOf(try m.placeOfLocal(f.d, local), &.{v}) else try f.project(v, .{ .kind = .field, .payload = @intCast(m.fieldRank(name)) });
            f.bindLocal(local, part);
        },
        // These bind no local.
        .wild, .int, .char, .string, .unit => {},
        // A spread binds through its list (`.list`); met anywhere else it is no pattern the lowering makes.
        .spread, .not_a_pattern => f.failed = true,
    }
}

/// A new match of a list pattern of `n` parts over `v`, when the list holds
/// each cell once (kernel §4.4, *The parts of a list pattern are apart*), or
/// `none`: `v` is a part of one root that is a parameter (the
/// apart-arguments rule), or a root the frame made that is `linear` with no
/// `twice` entry. Any other value, and a pattern of more parts than a
/// position can name, carries no position.
fn listParts(f: *Frame, v: Val, n: usize) Error!u32 {
    if (v == v_none or v == v_outside) return none;
    const node_v = f.nodes.items[v];
    if (node_v.tag != .ref) return none;
    if (n >= (1 << pos_bits)) return none;
    if (!try f.holdsEachOnce(node_v.a)) return none;
    return f.newMatch();
}

/// Whether root `root` holds each cell once (kernel §4.4): a parameter, by
/// the apart-arguments rule, or a root the frame made that is `linear` with
/// no `twice` entry. No other root has the claim.
fn holdsEachOnce(f: *Frame, root: u32) Error!bool {
    const r = f.roots.items[root];
    switch (r.kind) {
        .param => return true,
        .local => {
            // Not decided yet is no.
            if (r.linear != .yes) return false;
            const len = f.m.loc.layouts.items[r.layout].len;
            // The scan of the root's entries is work (kernel §8).
            if (f.charge(Loc.scanUnits(len))) return false;
            for (f.rents.items[r.ent..][0..len]) |ent| if (ent.twice) return false;
            return true;
        },
        // No claim that a cell is at one place of it.
        .capture, .answer, .fresh, .outside => return false,
    }
}

/// A new match, or `none` past the matches a position can name (the pessimistic side).
fn newMatch(f: *Frame) u32 {
    if (f.m.next_match >= (none >> pos_bits)) return none;
    const match = f.m.next_match;
    f.m.next_match += 1;
    return match;
}

/// The match of the positions of the list `v` that the index local of
/// instruction `idx` names (kernel §6 rule 10, *A position*): position 0 is
/// the element at that index (`pos_at`), position 1 every other element
/// (`pos_other`). One match for each list and local in the frame, so a
/// `get` and a `set` at one index of one list read one match. The list is
/// a part of a root at a location that names one value (no element step or
/// deep level on the way: `Loc.Entry.single`), and with the position it was
/// read at, if any (a list pattern's spread is a view of other indices than
/// its list's); the root holds each cell once (`holdsEachOnce`); the index is
/// a local this frame bound, which a frame binds once. Else `none`.
fn posKey(f: *Frame, v: Val, idx: u32) Error!u32 {
    if (idx == none or v == v_none or v == v_outside) return none;
    const m = f.m;
    if (m.tags[idx] != .local) return none;
    const local = m.datas[idx].lhs;
    if (m.lframe[f.d.locals_start + local] != f.id) return none;
    const n = f.nodes.items[v];
    if (n.tag != .ref) return none;
    if (!try f.holdsEachOnce(n.a)) return none;
    const r = f.roots.items[n.a];
    const p = m.loc.paths.items[n.b];
    const pes = m.loc.layoutEntries(try m.loc.layoutOf(p.place));
    // The scan of the part's layout and of the root's is work (kernel §8).
    if (f.charge(Loc.scanUnits(pes.len))) return none;
    const self = for (pes, 0..) |pe, k| {
        if (pe.loc == 0) break k;
    } else return none;
    const re = p.to_root[self];
    if (re == none or !m.loc.layoutEntries(r.layout)[re].single) return none;
    const key: [4]u32 = .{ n.a, n.b, n.pos, local };
    const got = try f.pos_keys.getOrPut(f.gpa, key);
    if (got.found_existing) return got.value_ptr.*;
    const match = f.newMatch();
    got.value_ptr.* = match;
    if (match != none) try f.pos_info.append(f.gpa, .{ match, key[0], key[1], key[2], key[3] });
    return match;
}

/// The position of a `get` (`elementof` with `position`) in its match.
const pos_at: u32 = 0;
/// The positions of the other elements of a `set` (`returned` beside
/// `stored`, with `position`) in its match.
const pos_other: u32 = 1;

/// `part`, read at position `k` of match `match` (`listParts`): a part of a
/// root, the same part with the position; any other value as it is.
fn atPosition(f: *Frame, part: Val, match: u32, k: usize) Error!Val {
    if (part == v_none or part == v_outside) return part;
    const n = f.nodes.items[part];
    if (n.tag != .ref) return part;
    var at = n;
    at.pos = match << pos_bits | @as(u32, @intCast(k));
    return f.node(at);
}

/// Whether matching pattern `pat` reads a list's storage.
fn readsList(f: *Frame, pat: u32) bool {
    // Each node of a pattern is work (kernel §8).
    _ = f.charge(1);
    const m = f.m;
    const data = m.datas[pat];
    switch (patTag(m.tags[pat])) {
        .list => return true,
        .as => return f.readsList(data.lhs),
        .tuple => {
            for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| if (f.readsList(p.int())) return true;
            return false;
        },
        .ctor => {
            for (m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index)) |p| if (f.readsList(p.int())) return true;
            return false;
        },
        // A pattern with no list in it, and no sub-pattern that has one (a record pattern binds locals).
        .wild, .variable, .int, .char, .string, .unit, .record => return false,
        // A spread is the rest of a list pattern, which `.list` has answered; alone it is taken to read the list.
        .spread => return true,
        .not_a_pattern => {
            f.failed = true;
            return true;
        },
    }
}

// ---- expressions ---------------------------------------------------------------------

const Mode = enum { value, callee, fn_arg, bind };

fn ev(f: *Frame, inst: u32) Error!Val {
    return f.eval(inst, .value, false);
}

/// The value of `inst`. In `tail` position it is the frame's answer, read where it is answered.
fn eval(f: *Frame, inst: u32, mode: Mode, tail: bool) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    // Each expression entered starts a new time for the operation after it (`timeOf`).
    f.entered += 1;
    // Each expression evaluated is a step (kernel §8): the rounds of nested
    // groups walk a body again and again. Past the budget the walk goes no
    // deeper; the declaration gave up, and a write it did not reach has no
    // line, so it is not authorised.
    if (f.tick()) return f.giveUp(inst);
    // A `let` and a `case` are answered here; every other instruction is
    // `evalInner`'s, whose switch names every tag.
    if (m.tags[inst] == .let) {
        const bindings = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.lhs)), Inst.Index);
        try f.enterLet(inst, bindings);
        for (bindings) |b| try f.binding(b.int());
        return f.eval(data.rhs, mode, tail);
    }
    if (m.tags[inst] == .case) return f.caseOf(inst, mode, tail);
    const v = try f.evalInner(inst, mode);
    if (mode == .value) try f.mention(v, inst);
    if (tail) {
        const before = f.uses.items.len;
        try f.readAll(v, inst);
        if (f.uses.items.len != before) f.uses.items[before].tail = true;
        if (!try f.makesObject(inst)) f.tail_old = true;
    }
    return v;
}

/// Whether `inst` makes the object that is its value: a record, a tuple or
/// a list literal, or a call of a declaration whose each answer is one of
/// these. A record update is not one: it answers its base's object, written
/// in place (kernel §11). A constructor application is not one:
/// a type of one constructor with one field is its field in a release build.
fn makesObject(f: *Frame, inst: u32) Error!bool {
    const m = f.m;
    switch (m.tags[inst]) {
        .record, .tuple, .list => return true,
        .call => {
            const callee = m.datas[inst].lhs;
            // A record alias's constructor builds a record (backend.md §4).
            if (m.tags[callee] == .ctor or m.tags[callee] == .ext_ctor) return m.isRecordPlace(try m.placeOfInst(inst));
            if (m.tags[callee] != .top and m.tags[callee] != .ext_value) return false;
            if (m.spreadOf(f.d, inst) != null) return false;
            const t = m.calleeOf(callee) orelse return false;
            const c = (try m.declContract(t)) orelse return false;
            return !c.old_result;
        },
        // False is the pessimistic answer here: the tail is then taken to answer an old value (`tail_old`).
        // A primitive: no object.
        .int,
        .float,
        .char,
        .string,
        .chunk,
        .interp,
        .unit,
        // The value exists already, or comes from code that makes no claim: a reference, a projection, an update, a dispatch, a function, a `?`, markup.
        .local,
        .top,
        .ctor,
        .import_value,
        .import_ctor,
        .qualified,
        .qualified_ctor,
        .schema_type_ref,
        .schema_value_ref,
        .schema_ctor_ref,
        .ext_value,
        .ext_ctor,
        .schema_member_top,
        .ext_schema_member,
        .schema_ctor_top,
        .ext_schema_ctor,
        .field_access,
        .tuple_index,
        .record_update,
        .method_call,
        .type_dispatch,
        .lambda,
        .@"try",
        .markup,
        // A `let` and a `case` are answered before a tail is read (`eval`); a binding or a branch is no value.
        .let,
        .let_def,
        .let_pattern,
        .let_stmt,
        .case,
        .branch,
        // Not expressions: a type, a schema plan, a pattern, the placeholder.
        .type_var,
        .type_top,
        .type_import,
        .type_qualified,
        .ext_type,
        .schema_type_top,
        .ext_schema_type,
        .type_app,
        .type_fn,
        .type_unit,
        .type_tuple,
        .type_record,
        .type_record_ext,
        .schema_ref,
        .schema_app,
        .schema_paren,
        .schema_record,
        .schema_field,
        .schema_value,
        .schema_tagged,
        .schema_variant,
        .schema_as,
        .schema_via,
        .schema_optional,
        .schema_nullable,
        .schema_expr_ref,
        .schema_parameter,
        .schema_primitive,
        .schema_target_top,
        .ext_schema_target,
        .pat_wild,
        .pat_var,
        .pat_ctor,
        .pat_int,
        .pat_char,
        .pat_string,
        .pat_unit,
        .pat_tuple,
        .pat_list,
        .pat_spread,
        .pat_record,
        .pat_as,
        .@"error",
        => return false,
    }
}

/// A function value is the value of an expression that no contract follows:
/// an item of a construction, an argument at a parameter that is no function
/// parameter, a result, the right side of a pattern. From here on it is in a
/// location with the default contract, so it flows to the `top` use (research
/// report 112 §2.3). A `case` is not here: each of its arms is.
fn mention(f: *Frame, v: Val, inst: u32) Error!void {
    switch (f.nodes.items[v].tag) {
        .closure, .fnref => {},
        .ref => if (!f.isFnRoot(f.ownFnRoot(v))) return,
        // A function in a value went to `top` where the value was made.
        .none, .outside, .built, .join, .unknown => return,
        .later => unreachable, // read through `capVal` only
    }
    try f.flowTop(v, inst);
}

fn flowTop(f: *Frame, v: Val, inst: u32) Error!void {
    const site: Site = .{ .inst = inst };
    const top: Use = .{ .kind = .top, .id = f.useId(), .key = inst, .site = &site };
    try f.flow(v, &top);
}

fn useId(f: *Frame) u32 {
    f.next_use += 1;
    return f.next_use - 1;
}

/// Whether the function lets one of its own parameters escape.
fn keepsOwn(f: *const Frame, c: *const Contract, own: u32) bool {
    const n = if (own <= c.arity) c.off[own] else c.flags.len;
    // The scan of the flags is work (kernel §8).
    _ = f.charge(Loc.scanUnits(n / 4));
    for (c.flags[0..n]) |x| if (x & flag_e != 0) return true;
    return false;
}

fn writesOwn(f: *const Frame, c: *const Contract, own: u32) bool {
    // No such parameter list: every location is one of them (the pessimistic side).
    const n = if (own <= c.arity) c.off[own] else c.flags.len;
    // The scan of the flags is work (kernel §8).
    _ = f.charge(Loc.scanUnits(n / 4));
    for (c.flags[0..n]) |x| if (x & flag_w != 0) return true;
    return false;
}

/// A local of an enclosing frame: a root of this one. It is one also when
/// the enclosing frame binds it after this code is made (a later local
/// function, or a value that a later binding gives): the contract then says
/// what the code does with it, and the frame that binds it reads that
/// contract with the value it binds (`capSlot`).
fn capture(f: *Frame, local: u32) Error!Val {
    const m = f.m;
    // A declaration's own frame binds each of its locals: it captures none.
    if (!f.is_lambda or m.lbinder[f.d.locals_start + local] == f.id) {
        f.failed = true;
        return f.unknownOf(try m.placeOfLocal(f.d, local), &.{});
    }
    for (f.cap_locals.items, 0..) |l, k| if (l == local) return f.rootVal(f.params.items[f.own_params + k]);
    const place = try m.placeOfLocal(f.d, local);
    // A local of no object needs no root; it holds `outside` (`rootVal`).
    if (try f.layoutLen(place) == 0) return v_outside;
    const root = try f.newRoot(.capture, place, none);
    f.roots.items[root].index = @intCast(f.params.items.len);
    // A capture's cells are followed as a parameter's are (kernel §13 item
    // 11): each holder that runs the code judges what it does to them.
    if (f.roots.items[root].cells) {
        f.roots.items[root].tracked = true;
        f.cells_any = true;
    }
    try f.params.append(f.gpa, root);
    try f.param_ty.append(f.gpa, m.typeOfLocal(f.d, local));
    try f.cap_locals.append(f.gpa, local);
    return f.rootVal(root);
}

fn evalInner(f: *Frame, inst: u32, mode: Mode) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    f.noteWalked(inst);
    switch (m.tags[inst]) {
        .int, .float, .char, .string, .chunk, .unit, .@"error" => return v_none,
        .ctor, .ext_ctor => return f.ctorValue(inst),
        .local => {
            const l = f.d.locals_start + data.lhs;
            // A code binding of a group whose rounds run (the code itself, or
            // another code of its cycle): the known function, with its
            // contract so far.
            if (m.lframe[l] == none) {
                const mv = try f.memberValue(data.lhs, inst);
                if (f.markup_reads) |mr| try mr.append(f.gpa, mv);
                return mv;
            }
            if (m.lframe[l] == f.id) {
                if (safety) std.debug.assert(m.lv[l] != v_unbound);
                if (f.markup_reads) |mr| try mr.append(f.gpa, m.lv[l]);
                return m.lv[l];
            }
            if (m.lbinder[l] == f.id) {
                // A later binding of this frame's own `let`. A local function
                // is hoisted, and nothing runs where code is bound, so it is
                // made here: what it reads is bound by now (language.md §7,
                // `let_forward_reference`).
                if (m.lframe[l] == 0 and m.lcode[l] != none) {
                    try f.makeCode(data.lhs);
                    return m.lv[l];
                }
                // A value read before it is bound: lowering refuses that.
                return f.giveUp(inst);
            }
            const cv = try f.capture(data.lhs);
            if (f.markup_reads) |mr| try mr.append(f.gpa, cv);
            return cv;
        },
        .field_access => {
            const base = try f.eval(data.lhs, .callee, false);
            if (base == v_none) return v_none;
            const rank: u32 = @intCast(m.fieldRank(@fromBackingInt(data.rhs)));
            // A field is read out of its record's slot, at this time (kernel §11).
            try f.readSlots(base, &.{rank}, inst);
            return f.project(base, .{ .kind = .field, .payload = @intCast(rank) });
        },
        .tuple_index => {
            const base = try f.eval(data.lhs, .callee, false);
            if (base == v_none) return v_none;
            return f.project(base, .{ .kind = .index, .payload = @intCast(data.rhs) });
        },
        .interp => {
            for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| {
                if (m.tags[p.int()] != .chunk) try f.readAll(try f.ev(p.int()), inst);
            }
            return v_none;
        },
        .top, .ext_value => {
            // A name that resolves to no declaration: unknown code, with nothing in sight.
            const t = m.calleeOf(inst) orelse return f.unknownResult(inst, &.{});
            _ = try f.evidence(inst);
            if (try m.isFunction(t)) return f.node(.{ .tag = .fnref, .a = t[0], .b = t[1] });
            // A top-level value: every reader has it, so each cell of it is
            // outside every frame (the position rule, kernel §3.1). Its
            // contract says which locations hold a cell; a location that
            // holds none (`Dict.empty`'s lists) holds none here. With no
            // contract (its walk gave up), each location can.
            const place = try m.placeOfInst(inst);
            const layout = try m.loc.layoutOf(place);
            const es = m.loc.layoutEntries(layout);
            if (es.len == 0) return v_none;
            const c = (try m.declContract(t)) orelse return v_outside;
            if (c.arity != 0) return v_outside;
            const cov = try m.loc.cover(c.layouts[0], layout);
            // The two scans of the map, and the one of the result, are work (kernel §8).
            _ = f.charge(2 * Loc.scanUnits(cov.len) + Loc.scanUnits(c.res.len));
            // A location that every entry of the contract's result covers
            // (`Loc.all`: a deep level read through a type variable, §4.1)
            // holds a cell only where some entry does: an entry with no
            // source holds none, as a fact of the body's walk (`Dict.empty`'s
            // values read as `Dict Int R`).
            const every = for (c.res) |r| {
                if (r.len != 0) break true;
            } else false;
            var any = false;
            for (cov) |cr| if (topHolds(c, cr, every)) {
                any = true;
            };
            if (!any) return v_none;
            const root = try f.newRoot(.local, place, inst);
            const ent0 = f.roots.items[root].ent;
            const start: u32 = @intCast(f.atoms.items.len);
            try f.atoms.append(f.gpa, outside_atom);
            for (cov, 0..) |cr, e| f.rents.items[ent0 + e] = if (topHolds(c, cr, every)) .{ .kind = .alias, .start = start, .len = 1 } else .{ .kind = .alias };
            try f.deriveLinear(root, null, &.{});
            return f.rootVal(root);
        },
        .tuple => {
            const items = m.bir.extraSlice(Bir.inlineRange(data), Inst.Index);
            const place = try m.placeOfInst(inst);
            var tmp: std.ArrayList(Kid) = .empty;
            defer tmp.deinit(f.gpa);
            for (items, 0..) |it, k| {
                const s: Step = .{ .kind = .index, .payload = @intCast(k) };
                try tmp.append(f.gpa, .{ .step = s.word(), .val = try f.ev(it.int()) });
            }
            return f.built(place, tmp.items);
        },
        .record => {
            const fields = m.bir.extraSlice(Bir.inlineRange(data), Bir.Field);
            const place = try m.placeOfInst(inst);
            var tmp: std.ArrayList(Kid) = .empty;
            defer tmp.deinit(f.gpa);
            for (fields) |fd| {
                const s: Step = .{ .kind = .field, .payload = @intCast(m.fieldRank(fd.name)) };
                try tmp.append(f.gpa, .{ .step = s.word(), .val = try f.ev(fd.value.int()) });
            }
            return f.recordOf(place, tmp.items, inst, v_none);
        },
        .record_update => return f.recordUpdate(inst),
        .list => {
            const items = m.bir.extraSlice(Bir.inlineRange(data), Inst.Index);
            var tmp: std.ArrayList(Val) = .empty;
            defer tmp.deinit(f.gpa);
            for (items) |it| try tmp.append(f.gpa, try f.ev(it.int()));
            return f.listOf(try m.placeOfInst(inst), inst, tmp.items, &.{}, v_none, v_none);
        },
        .lambda => {
            const params = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.lhs)), Inst.Index);
            return f.codeValue(inst, params, data.rhs, m.typeOfInst(inst), none);
        },
        .@"try" => {
            const v = try f.ev(data.lhs);
            // The failure leaves the function here, whatever the scrutinee
            // holds: what the calls before left in the parameters' cells is
            // what the caller reads (kernel §13).
            if (v == v_none) {
                try f.writersAtReturn(inst, v_none);
                try f.noteReturnCells(inst);
                return v_none;
            }
            // The failure leaves the function with the scrutinee's other arm:
            // an answer that is an object made before (`Contract.old_result`).
            try f.readAll(v, inst);
            try f.writersAtReturn(inst, v);
            try f.returns.append(f.gpa, try f.cellsNow(v));
            try f.noteReturnCells(inst);
            f.tail_old = true;
            // The success: the argument of `Ok` or `Just`, a part of the
            // scrutinee. A `smear` of it would claim its cells and lose that
            // one cell can be at two of its locations.
            if (try m.trySuccess(data.lhs)) |s| return f.project(v, s);
            return f.unknownOf(try m.placeOfInst(inst), &.{v});
        },
        .call => return f.call(inst, mode),
        .method_call => return f.methodCall(inst),
        .type_dispatch => {
            // Code of the compiler's own that the walk does not follow: each argument escapes, and the answer can hold each.
            const t = m.bir.extraData(@fromBackingInt(data.rhs), Bir.TypeDispatch);
            var vals: std.ArrayList(Val) = .empty;
            defer vals.deinit(f.gpa);
            for (m.bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Inst.Index)) |a| try vals.append(f.gpa, try f.ev(a.int()));
            // The code it runs, and what that calls, as a derived callee (kernel §6.11).
            const x = try f.evidenceAt(inst, true);
            try f.derivedEffect(inst, x, vals.items, &.{});
            for (vals.items) |v| try f.escape(v, inst);
            return f.unknownResult(inst, vals.items);
        },
        .markup => {
            var ops: std.ArrayList(Inst.Index) = .empty;
            defer ops.deinit(f.gpa);
            try m.bir.markupValues(f.gpa, @fromBackingInt(data.lhs), &ops);
            // The value of markup holds the value of each of its holes
            // (kernel §6.12): a platform's runtime reads them where it
            // renders, after this frame. So the markup is `unknown` over
            // them, and whoever holds the markup holds them until it is
            // rendered; the runtime keeps none of them after the render
            // (`boundary.md` §9.4.8, read at the entry: `entryCall`). A
            // message that the frame makes here, or a function
            // that answers one, is kept by the runtime beyond the markup's
            // own life (it is sent back on an event): what it holds escapes.
            //
            // A hole that calls a function of the top level is a helper: the
            // platform may make the call where it renders (`language.md` §6,
            // *Evaluation order*; §11.6), so what the call was handed is held
            // by the markup too, as the call's value is. And a lowering may
            // evaluate any hole where it renders, from the values the hole
            // reads (the `dom` lowering's block of inputs, `backend.md`
            // §15.4): so the markup holds every local that a hole reads, not
            // only the hole's value.
            const vals = try f.gpa.alloc(Val, ops.items.len);
            var held: std.ArrayList(Val) = .empty;
            defer held.deinit(f.gpa);
            var helpers: std.ArrayList(u32) = .empty;
            defer helpers.deinit(f.gpa);
            try f.helperHoles(@fromBackingInt(data.lhs), &helpers);
            const outer_reads = f.markup_reads;
            f.markup_reads = &held;
            defer f.markup_reads = outer_reads;
            // Per value: the run of `held` that its evaluation read.
            const reads = try f.gpa.alloc([2]u32, ops.items.len);
            defer f.gpa.free(reads);
            for (ops.items, vals, reads) |o, *v, *rd| {
                rd[0] = @intCast(held.items.len);
                v.* = try f.ev(o.int());
                try held.append(f.gpa, v.*);
                if (f.call_inst == o.int() and std.mem.indexOfScalar(u32, helpers.items, o.int()) != null) try held.appendSlice(f.gpa, f.call_vals);
                rd[1] = @intCast(held.items.len);
            }
            f.markup_reads = outer_reads;
            // The runtime calls the functions that the markup gives it with
            // items of the markup's own values (`boundary.md` §9.4.8): a
            // `For`'s row and key function with each item of `each`, a
            // `Show`'s body and key function with the value in `when`. Each
            // is applied to them as at a call site (`runtimeCall`), so what
            // it keeps of them escapes and what it hands a function is
            // supplied.
            try f.formCalls(inst, @fromBackingInt(data.lhs), ops.items, vals);
            // A value at an item that no row names as an attribute — an
            // event's handler or message, a component's prop, a spread — is
            // kept by the runtime past the render, and called or sent after
            // `update` runs (`boundary.md` §9.4.8): it escapes, whatever
            // made it. An attribute's value is read where it is rendered.
            //
            // A component's children are a value that its code is handed
            // whole (`children`, `language.md` §11.8), markup that holds
            // everything its holes read: each of those escapes.
            var unrendered: std.ArrayList(u32) = .empty;
            defer unrendered.deinit(f.gpa);
            var handed: std.ArrayList(u32) = .empty;
            defer handed.deinit(f.gpa);
            try f.keptItems(@fromBackingInt(data.lhs), &unrendered, &handed);
            for (ops.items, vals, reads) |o, v, rd| {
                if (std.mem.indexOfScalar(u32, handed.items, o.int()) != null) {
                    for (held.items[rd[0]..rd[1]]) |x| try f.escape(x, inst);
                    continue;
                }
                const kept = std.mem.indexOfScalar(u32, unrendered.items, o.int()) != null or try f.keptHole(v);
                if (kept) try f.escape(v, inst) else try f.readAll(v, inst);
            }
            return f.unknownOf(try m.placeOfInst(inst), held.items);
        },
        // Not an expression: a reference the resolver did not rewrite, a
        // type, a schema plan, a pattern, a binding, a branch. The walk
        // cannot say what is here, so it gives up on the declaration.
        .import_value,
        .import_ctor,
        .qualified,
        .qualified_ctor,
        .schema_type_ref,
        .schema_value_ref,
        .schema_ctor_ref,
        .type_var,
        .type_top,
        .type_import,
        .type_qualified,
        .ext_type,
        .schema_type_top,
        .ext_schema_type,
        .type_app,
        .type_fn,
        .type_unit,
        .type_tuple,
        .type_record,
        .type_record_ext,
        .schema_ref,
        .schema_app,
        .schema_paren,
        .schema_record,
        .schema_field,
        .schema_value,
        .schema_tagged,
        .schema_variant,
        .schema_as,
        .schema_via,
        .schema_optional,
        .schema_nullable,
        .schema_expr_ref,
        .schema_parameter,
        .schema_primitive,
        .schema_target_top,
        .ext_schema_target,
        .let,
        .let_def,
        .let_pattern,
        .let_stmt,
        .case,
        .branch,
        .pat_wild,
        .pat_var,
        .pat_ctor,
        .pat_int,
        .pat_char,
        .pat_string,
        .pat_unit,
        .pat_tuple,
        .pat_list,
        .pat_spread,
        .pat_record,
        .pat_as,
        => return f.giveUp(inst),
        // A schema's member is a function of the compiler's own: it
        // captures nothing of the frame, and it is in the default state. A
        // schema's constructor makes a value and runs no code; no row
        // describes it, so its value holds nothing of the frame and a call
        // of it is code with no contract: each argument escapes (§3.2,
        // kernel §6.14). In a pattern it is a tag test, and the pattern
        // binds `unknown` over the scrutinee (`bindPattern`, rule 6).
        .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor => return v_outside,
    }
}

/// The `For` and `Show` forms of the markup at `root`, each with its
/// functions applied to what the runtime hands them (kernel §6.12). `ops`
/// and `vals` are the markup's values (`Bir.markupValues`) and theirs.
fn formCalls(f: *Frame, inst: u32, root: Bir.ExtraIndex, ops: []const Inst.Index, vals: []const Val) Error!void {
    // Each node of the markup is work (kernel §8).
    _ = f.charge(1);
    const m = f.m;
    const bir = m.bir;
    switch (bir.markupKind(root)) {
        .element => {
            const e = bir.extraData(root, Bir.MarkupElement);
            for (bir.extraSlice(.{ .start = e.children_start, .end = e.children_end }, Bir.ExtraIndex)) |c| try f.formCalls(inst, c, ops, vals);
        },
        .fragment => {
            const fr = bir.extraData(root, Bir.MarkupFragment);
            for (bir.extraSlice(.{ .start = fr.children_start, .end = fr.children_end }, Bir.ExtraIndex)) |c| try f.formCalls(inst, c, ops, vals);
        },
        .component => {
            const c = bir.extraData(root, Bir.MarkupComponent);
            for (bir.extraSlice(.{ .start = c.children_start, .end = c.children_end }, Bir.ExtraIndex)) |ch| try f.formCalls(inst, ch, ops, vals);
        },
        .text, .hole => {},
        .@"for", .show => {
            const k = bir.markupKind(root);
            const form = bir.extraData(root, Bir.MarkupForm);
            const list = form.list.unwrap() orelse return;
            const lv = valOf(ops, vals, list.int());
            // What the runtime hands: an item of the list, or the value in `Just`.
            const item = if (k == .@"for") try f.project(lv, Step.elem) else try f.project(lv, try m.ctorStep(0, 0));
            if (form.mode == .key_function) if (form.keyed.unwrap()) |kf| try f.runtimeCall(inst, kf.int(), valOf(ops, vals, kf.int()), item);
            if (form.row != Bir.none_extra) {
                const rf = bir.extraData(@fromBackingInt(@intCast(form.row)), Bir.MarkupRow).function.int();
                try f.runtimeCall(inst, rf, valOf(ops, vals, rf), item);
            }
        },
    }
}

fn valOf(ops: []const Inst.Index, vals: []const Val, inst: u32) Val {
    for (ops, vals) |o, v| if (o.int() == inst) return v;
    unreachable; // every value of the markup is in `ops`
}

/// The runtime calls the function `fv` (the value of `fn_inst`) with `item`,
/// and a row's position, where it renders the markup `inst`: applied as at a
/// call site. A function that no rule follows is unknown code: the item and
/// the function escape. The answer is markup the runtime renders, or a key
/// of no list.
fn runtimeCall(f: *Frame, inst: u32, fn_inst: u32, fv: Val, item: Val) Error!void {
    const m = f.m;
    const n = f.nodes.items[fv];
    if (n.tag == .join) {
        for (0..n.b) |ki| try f.runtimeCall(inst, fn_inst, f.lists.items[n.a + 2 * ki], item);
        return;
    }
    const ft = m.fnType(m.typeOfInst(fn_inst));
    const arity: usize = if (ft) |t| m.in.store.vars(t.params).len else 0;
    // The item, and for a row of two parameters its position, an `Int`.
    const args = [2]Val{ item, v_none };
    if (arity == 1 or arity == 2) {
        if (try f.codeOf(fv)) |code| if (code.own_params == arity) {
            _ = try f.applyAt(inst, fn_inst, code, args[0..arity], &.{}, try m.placeOfInst(inst));
            return;
        };
        const root = f.ownFnRoot(fv);
        if (f.isFnRoot(root)) {
            _ = try f.callParam(inst, fn_inst, root, args[0..arity], &.{});
            return;
        }
    }
    try f.escape(item, inst);
    try f.escape(fv, inst);
}

/// The values of the items of the markup at `root` that the runtime can keep
/// past the render: every item that no row of the dispatch table names as an
/// attribute or a quoted attribute (an event's handler or message, a
/// component's prop, a spread of attributes). A missing row is the
/// pessimistic fact: kept.
fn keptItems(f: *Frame, root: Bir.ExtraIndex, out: *std.ArrayList(u32), handed: *std.ArrayList(u32)) Error!void {
    // Each node of the markup is work (kernel §8).
    _ = f.charge(1);
    const m = f.m;
    const bir = m.bir;
    switch (bir.markupKind(root)) {
        .element => {
            const e = bir.extraData(root, Bir.MarkupElement);
            try f.keptOf(e.items_start, e.items_end, out);
            for (bir.extraSlice(.{ .start = e.children_start, .end = e.children_end }, Bir.ExtraIndex)) |c| try f.keptItems(c, out, handed);
        },
        .fragment => {
            const fr = bir.extraData(root, Bir.MarkupFragment);
            for (bir.extraSlice(.{ .start = fr.children_start, .end = fr.children_end }, Bir.ExtraIndex)) |c| try f.keptItems(c, out, handed);
        },
        .component => {
            const c = bir.extraData(root, Bir.MarkupComponent);
            // A component's props and spread go to code that the walk does not follow here.
            for (bir.extraSlice(.{ .start = c.props_start, .end = c.props_end }, Bir.ExtraIndex)) |at| {
                if (bir.extraData(at, Bir.MarkupItem).value.unwrap()) |v| try out.append(f.gpa, v.int());
            }
            if (c.spread.unwrap()) |s| try out.append(f.gpa, s.int());
            // Its children are a prop too (`children`, `language.md` §11.8):
            // that code is handed every value in them, and what they read.
            var tmp: std.ArrayList(Inst.Index) = .empty;
            defer tmp.deinit(f.gpa);
            for (bir.extraSlice(.{ .start = c.children_start, .end = c.children_end }, Bir.ExtraIndex)) |ch| try bir.markupValues(f.gpa, ch, &tmp);
            for (tmp.items) |v| try handed.append(f.gpa, v.int());
        },
        .text, .hole, .@"for", .show => {},
    }
}

/// Whether the value `v` of a hole is kept by the runtime past the render
/// (kernel §6.12): a value built here, or a function that answers anything
/// but markup. One of several values is kept where any of them is: an
/// `if` or a `case` whose arm builds one (research report 148: a `join`
/// was read, never kept, whatever its arms were). Each arm is work (kernel
/// §8); past the budget the value is kept.
fn keptHole(f: *Frame, v: Val) Error!bool {
    const n = f.nodes.items[v];
    return switch (n.tag) {
        .built => true,
        .closure => blk: {
            // A function that answers markup is a part of the view.
            const lc = f.codes.items[n.a].contract;
            for (f.m.loc.layoutEntries(lc.layouts[lc.arity])) |e| if (e.kind != .@"opaque") break :blk true;
            break :blk false;
        },
        .join => blk: {
            if (f.charge(n.b)) break :blk true;
            for (0..n.b) |i| if (try f.keptHole(f.lists.items[n.a + 2 * i])) break :blk true;
            break :blk false;
        },
        .none, .outside, .ref, .fnref, .unknown => false,
        .later => unreachable, // read through `capVal` only
    };
}

fn keptOf(f: *Frame, start: Bir.ExtraIndex, end: Bir.ExtraIndex, out: *std.ArrayList(u32)) Error!void {
    const m = f.m;
    const bir = m.bir;
    for (bir.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |at| {
        const v = bir.extraData(at, Bir.MarkupItem).value.unwrap() orelse continue;
        var rendered = false;
        if (m.in.dispatch) |dt| for (dt.markup) |row| if (row.node == @backingInt(at)) switch (row.kind) {
            .attribute, .escape => rendered = true,
            .event, .element, .hole, .@"for", .show => {},
        };
        if (!rendered) try out.append(f.gpa, v.int());
    }
}

/// The values of the holes of the markup at `root` that call a function of
/// the top level and that a platform may call where it renders (the
/// emitter's `helperCallee`, `language.md` §11.6). A hole whose value is
/// text is one too: a lowering may evaluate it where it renders (the `dom`
/// lowering's block of inputs, `backend.md` §15.4). A function of another
/// module is taken to be one: a markup primitive among them only reads
/// later than it does.
fn helperHoles(f: *Frame, root: Bir.ExtraIndex, out: *std.ArrayList(u32)) Error!void {
    // Each node of the markup is work (kernel §8).
    _ = f.charge(1);
    const m = f.m;
    const bir = m.bir;
    switch (bir.markupKind(root)) {
        .element => {
            const e = bir.extraData(root, Bir.MarkupElement);
            for (bir.extraSlice(.{ .start = e.children_start, .end = e.children_end }, Bir.ExtraIndex)) |c| try f.helperHoles(c, out);
        },
        .fragment => {
            const fr = bir.extraData(root, Bir.MarkupFragment);
            for (bir.extraSlice(.{ .start = fr.children_start, .end = fr.children_end }, Bir.ExtraIndex)) |c| try f.helperHoles(c, out);
        },
        .component => {
            const c = bir.extraData(root, Bir.MarkupComponent);
            for (bir.extraSlice(.{ .start = c.children_start, .end = c.children_end }, Bir.ExtraIndex)) |ch| try f.helperHoles(ch, out);
        },
        .text, .@"for", .show => {},
        .hole => {
            const v = bir.extraData(root, Bir.MarkupHole).value.int();
            if (m.tags[v] != .call) return;
            const callee = m.datas[v].lhs;
            switch (m.tags[callee]) {
                .top => {
                    const d = m.datas[callee].lhs;
                    if (d >= bir.decls.len) return;
                    const k = bir.decls[d].kind;
                    if (!k.isValue() or k == .vocab_markup) return;
                },
                .ext_value => {},
                // The emitter's `helperCallee` takes a call of a top-level function and no other callee: a local
                // function could capture what its arguments do not show, and the rest name no function of the top level.
                .local,
                .ctor,
                .import_value,
                .import_ctor,
                .qualified,
                .qualified_ctor,
                .schema_type_ref,
                .schema_value_ref,
                .schema_ctor_ref,
                .ext_ctor,
                .schema_member_top,
                .ext_schema_member,
                .schema_ctor_top,
                .ext_schema_ctor,
                .type_var,
                .type_top,
                .type_import,
                .type_qualified,
                .ext_type,
                .schema_type_top,
                .ext_schema_type,
                .type_app,
                .type_fn,
                .type_unit,
                .type_tuple,
                .type_record,
                .type_record_ext,
                .schema_ref,
                .schema_app,
                .schema_paren,
                .schema_record,
                .schema_field,
                .schema_value,
                .schema_tagged,
                .schema_variant,
                .schema_as,
                .schema_via,
                .schema_optional,
                .schema_nullable,
                .schema_expr_ref,
                .schema_parameter,
                .schema_primitive,
                .schema_target_top,
                .ext_schema_target,
                .int,
                .float,
                .char,
                .string,
                .chunk,
                .interp,
                .unit,
                .tuple,
                .list,
                .record,
                .record_update,
                .field_access,
                .tuple_index,
                .call,
                .method_call,
                .type_dispatch,
                .lambda,
                .let,
                .let_def,
                .let_pattern,
                .let_stmt,
                .case,
                .branch,
                .@"try",
                .markup,
                .pat_wild,
                .pat_var,
                .pat_ctor,
                .pat_int,
                .pat_char,
                .pat_string,
                .pat_unit,
                .pat_tuple,
                .pat_list,
                .pat_spread,
                .pat_record,
                .pat_as,
                .@"error",
                => return,
            }
            try out.append(f.gpa, v);
        },
    }
}

/// A constructor used as a function value: its contract says that the
/// result's argument `k` is parameter `k`, location for location (for a
/// record alias's constructor, the field that argument `k` is; backend.md
/// §4). A constructor that the walk has no row for is a function in the
/// default state: it captured nothing of the frame (`outside`), it asks
/// nothing, and its answer can hold each value in sight (research report
/// 112 §2.5). It is never "no function".
fn ctorValue(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const ty = m.typeOfInst(inst);
    // A constructor with no argument is a value of no object, not a function.
    const ft = m.fnType(ty) orelse return v_none;
    const info = m.ctorInfo(inst) orelse return v_outside;
    const pvars = m.in.store.vars(ft.params);
    if (pvars.len != info.arity) return v_outside;
    const rplace = try m.placeOf(ft.result.toOptional());
    if (try f.layoutLen(rplace) == 0) return v_none;
    if (m.code_contract[inst] == null) {
        const params = try f.gpa.alloc(PlaceId, pvars.len);
        for (params, pvars) |*p, v| p.* = try m.placeOf(v.toOptional());
        const c = try m.emptyContract(params, rplace);
        const lists = try f.gpa.alloc(std.ArrayList(Src), c.res.len);
        for (lists) |*l| l.* = .empty;
        for (0..info.arity) |k| {
            const step = (try m.ctorArgStep(inst, rplace, @intCast(k))) orelse return v_outside;
            const pr = (try m.loc.proj(rplace, step)) orelse return v_outside;
            const cl = try m.loc.layoutOf(pr.child);
            const child = m.loc.layoutEntries(cl);
            for (0..child.len) |j| {
                if (pr.up[j] == none) continue;
                // The argument's entries that can be this part's: the call map, not label paths.
                for (0..m.loc.layoutEntries(c.layouts[k]).len) |pj| if (try f.locsMeet(c.layouts[k], @intCast(pj), cl, @intCast(j))) try lists[pr.up[j]].append(f.gpa, .{ .kind = .param, .a = @intCast(k), .e = @intCast(pj) });
            }
        }
        // A record alias's constructor makes the record's object, as its
        // literal does (`recordOf`, kernel §11.2): each slot is a cell it
        // made, a site of its own, which no other holder has. With no
        // source, a slot of its answer held no cell (research report 147).
        if (m.isRecordPlace(rplace)) {
            const es = m.loc.layoutEntries(c.layouts[info.arity]);
            for (es, 0..) |e, j| if (f.isOwnSlot(e.loc)) try lists[j].append(f.gpa, Src.fresh(try m.siteId(std.hash.Wyhash.hash(inst, std.mem.asBytes(&j))), false));
        }
        const res = @constCast(c.res);
        for (res, lists) |*r, l| r.* = try CMod.normal(m.arena, l.items);
        for (@constCast(c.flags)) |*x| x.* = flag_r;
        m.code_contract[inst] = c;
    }
    try f.codes.append(f.gpa, .{ .contract = m.code_contract[inst].?, .inst = inst, .own_params = info.arity });
    return f.node(.{ .tag = .closure, .place = try m.placeOf(ty), .a = @intCast(f.codes.items.len - 1) });
}

/// The answer of code the walk does not follow at `inst`: no claim, and it
/// can hold each cell of the values `in_sight` (kernel §3.2).
fn unknownResult(f: *Frame, inst: u32, in_sight: []const Val) Error!Val {
    return f.unknownOf(try f.m.placeOfInst(inst), in_sight);
}

fn built(f: *Frame, place: PlaceId, kids: []const Kid) Error!Val {
    // A construction of a type with no location holds a cell only where a
    // part does, which a cast put there: `outside` (`rootVal`).
    if (try f.layoutLen(place) == 0) {
        for (kids) |k| if (k.val != v_none) return v_outside;
        return v_none;
    }
    // A construction at a record's place holds the record's object, whose
    // slots are cells (kernel §11.2, `recordOf`): a construction of the
    // fields alone held no slot, and an update of it wrote no cell
    // (research report 147). The check counts no work (kernel §9).
    if (std.debug.runtime_safety and f.m.isRecordPlace(place)) {
        const has_object = for (kids) |k| {
            if (k.step == slot_kid) break true;
        } else false;
        if (!has_object) for (f.m.loc.layoutEntries(try f.m.loc.layoutOf(place)), 0..) |e, j| if (f.isOwnSlot(e.loc))
            std.debug.panic("own3: a record construction at place {d} has no object, and its slot {d} holds no cell", .{ place, j });
    }
    var any = false;
    for (kids) |k| if (k.val != v_none) {
        any = true;
    };
    if (!any) return v_none;
    const start: u32 = @intCast(f.kids.items.len);
    try f.kids.appendSlice(f.gpa, kids);
    return f.node(.{ .tag = .built, .place = place, .a = start, .b = @intCast(kids.len) });
}

/// A list this frame makes: its own cell, and its elements from `elems`
/// (each one element) and from `spreads` (each a list of elements). `base`
/// is a list whose storage the result takes (a construction's base).
/// `front` is the spread of a prepend `[ x, …xs ]`: the result can be the
/// array that `xs` is a view of (`List.cons` puts back the element that a
/// pattern took off), so its storage is the spread's too.
fn listOf(f: *Frame, place: PlaceId, inst: u32, elems: []const Val, spreads: []const Val, base: Val, front: Val) Error!Val {
    const m = f.m;
    // Past the budget (kernel §8) the walk builds nothing more: the
    // declaration gave up. The projection below is work of the location
    // table, and a list nested 400 deep made one for each level on the way
    // back up, each the size of its layout times its depth, long after the
    // budget was passed (research report 138).
    if (m.steps_over) {
        f.failed = true;
        return f.unknownOf(place, &.{});
    }
    const pr = try m.loc.proj(place, Step.elem);
    if (pr == null) {
        // A list whose place has no element step (a literal typed by a
        // callee's type variable: `Js.apply f [ x ]`, `Js.object [ … ]`)
        // has no location for its elements, so it is `unknown` over every
        // value it was made of (kernel §3.2, §6.4): dropping them would read
        // "no location" as "no cell".
        var made: std.ArrayList(Val) = .empty;
        defer made.deinit(f.gpa);
        try made.appendSlice(f.gpa, elems);
        try made.appendSlice(f.gpa, spreads);
        for ([_]Val{ base, front }) |v| if (v != v_none) try made.append(f.gpa, v);
        return f.unknownOf(place, made.items);
    }
    const root = try f.newRoot(.local, place, inst);
    const r = f.roots.items[root];
    const es = m.loc.layoutEntries(r.layout);
    const self = try m.selfLoc(place);
    for (0..es.len) |e| {
        if (es[e].loc == self) {
            // The storage: the frame's own cell (`own`), or the base's array
            // under a new name (`version`), or its own or the array of a
            // prepend's base (`derived`). An outside atom among them refuses
            // a write by itself (`demand`).
            if (base == v_none) {
                if (front == v_none) continue;
                const start: u32 = @intCast(f.atoms.items.len);
                const dup = try f.leavesAs(front, place, @intCast(e), &f.atoms);
                try f.uniqueTail(&f.atoms, start);
                // One cell at two places of the storage: its parts are not apart (`leavesOwn`).
                f.rents.items[r.ent + e] = .{ .kind = .derived, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = dup };
                continue;
            }
            const start: u32 = @intCast(f.atoms.items.len);
            const dup = try f.leavesAs(base, place, @intCast(e), &f.atoms);
            // The base's storage is the result's: its names here are old.
            for (f.atoms.items[start..]) |*a| a.dead = f.timeOf(inst);
            try f.uniqueTail(&f.atoms, start);
            f.rents.items[r.ent + e] = .{ .kind = .version, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = dup };
            continue;
        }
        // The elements: the cells of other roots, each element one part.
        const start: u32 = @intCast(f.atoms.items.len);
        var dup = false;
        var parts: std.ArrayList([2]u32) = .empty;
        defer parts.deinit(f.gpa);
        for (elems) |v| {
            if (v == v_none) continue;
            const before: u32 = @intCast(f.atoms.items.len);
            // The element's entries that fold into this one are one set (`leavesOwn`).
            const js = pr.?.downOf(@intCast(e));
            if (js.len != 0 and try f.leavesSet(v, pr.?.child, js, &f.atoms)) dup = true;
            try parts.append(f.gpa, .{ before, @intCast(f.atoms.items.len) });
        }
        for (spreads) |v| {
            if (v == v_none) continue;
            const before: u32 = @intCast(f.atoms.items.len);
            if (try f.leavesAs(v, place, @intCast(e), &f.atoms)) dup = true;
            try parts.append(f.gpa, .{ before, @intCast(f.atoms.items.len) });
        }
        if (!dup and try f.partDup(f.atoms.items, start, parts.items)) dup = true;
        try f.uniqueTail(&f.atoms, start);
        // One cell at two places of the location: it keeps what it holds,
        // and its parts are not apart (kernel §4.4).
        f.rents.items[r.ent + e] = .{ .kind = .alias, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = dup };
    }
    try f.deriveLinear(root, null, &.{});
    // A handle among the elements is held by the list too (kernel §13).
    try f.shareCopies(root, null, inst);
    return f.rootVal(root);
}

/// A call of `Record.copy` (`Contract.record_copy`, kernel §11): it reads
/// every slot of the record `v` and answers a new object, a record this
/// frame makes, whose fields hold `v`'s values.
fn recordCopy(f: *Frame, v: Val, inst: u32, place: PlaceId) Error!Val {
    const m = f.m;
    try f.readSlots(v, &.{}, inst);
    if (v == v_none) return f.recordOf(place, &.{}, inst, v_none);
    const vplace = f.placeOfVal(v) orelse place;
    const st = m.places.steps(vplace);
    // Each part copied is a step of the budget (kernel §8).
    _ = f.charge(st.steps.len);
    var kids: std.ArrayList(Kid) = .empty;
    defer kids.deinit(f.gpa);
    for (st.steps) |s| {
        if (s.kind == .level) continue;
        const part = try f.project(v, s);
        if (part == v_none) continue;
        try kids.append(f.gpa, .{ .step = s.word(), .val = part });
    }
    return f.recordOf(place, kids.items, inst, v_none);
}

/// `{ r | f₁ = v₁, … }` (kernel §11): a write of `r`'s object, at the slots
/// of the fields it names, after every value is evaluated. Its answer is the
/// same object: each slot of it is `r`'s under a new name (`version`), each
/// field it does not name holds `r`'s part there, and each field it names
/// holds the new value. The values are the operation's other operands: a
/// value that reaches a written slot (a record that holds `r` itself) would
/// see the store.
fn recordUpdate(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    const fields = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Bir.Field);
    const base = try f.eval(data.lhs, .callee, false);
    const place = try m.placeOfInst(inst);
    var tmp: std.ArrayList(Kid) = .empty;
    defer tmp.deinit(f.gpa);
    const ranks = try f.gpa.alloc(u32, fields.len);
    defer f.gpa.free(ranks);
    for (fields, ranks) |fd, *rank| {
        rank.* = @intCast(m.fieldRank(fd.name));
        const s: Step = .{ .kind = .field, .payload = @intCast(rank.*) };
        try tmp.append(f.gpa, .{ .step = s.word(), .val = try f.ev(fd.value.int()) });
    }
    if (base == v_none) {
        // A record always holds its object (kernel §11.2): a base of no cell
        // (a number read as a record through `Js.to`) is an object no cell
        // names, and the write of its slots has no claim (kernel §3.4), as a
        // slot write whose atoms are none below. Before, it made no demand
        // at all (research report 148).
        const w: u32 = @intCast(f.atoms.items.len);
        try f.atoms.append(f.gpa, outside_atom);
        const os = try f.gpa.alloc(Other, tmp.items.len);
        for (os, tmp.items) |*o, k| o.* = .{ .v = k.val };
        try f.demand(w, .{ .point = inst, .op = .update, .kind = .update, .base_inst = data.lhs, .others = os });
        return f.recordOf(place, tmp.items, inst, v_none);
    }
    // The write: the slots of the fields named, with every value as an operand.
    const w: u32 = @intCast(f.atoms.items.len);
    try f.slotAtoms(base, ranks, &f.atoms);
    // A record always holds its object (kernel §11.2): slots that hold no
    // cell are of an object no cell names (a tuple of numbers read as a
    // record below a callee's type variable), and the write has no claim on
    // it (kernel §3.4; research report 147).
    if (f.atoms.items.len == w) try f.atoms.append(f.gpa, outside_atom);
    const os = try f.gpa.alloc(Other, tmp.items.len);
    for (os, tmp.items) |*o, k| o.* = .{ .v = k.val };
    try f.demand(w, .{ .point = inst, .op = .update, .kind = .update, .base_inst = data.lhs, .others = os });
    // The base whole is read here: a copy reads each field of it, and a
    // name of the record older than a write of it reads a slot that changed
    // (the sanitiser's copy traps there).
    try f.readSlots(base, &.{}, inst);
    // The update copies the record: each other field is the base's.
    const bplace = f.placeOfVal(base) orelse place;
    const st = m.places.steps(bplace);
    // The fields named, sorted, so that each part is looked up once and
    // not compared with every field named (research report 145).
    const named = try f.gpa.alloc(u32, tmp.items.len);
    defer f.gpa.free(named);
    for (named, tmp.items) |*n, k| n.* = k.step;
    std.mem.sortUnstable(u32, named, {}, std.sort.asc(u32));
    // Each part copied is a step of the budget (kernel §8).
    _ = f.charge(st.steps.len);
    for (st.steps) |s| {
        if (s.kind == .level) continue;
        if (std.sort.binarySearch(u32, named, s.word(), struct {
            fn order(x: u32, y: u32) std.math.Order {
                return std.math.order(x, y);
            }
        }.order) != null) continue;
        const part = try f.project(base, s);
        if (part == v_none) continue;
        try tmp.append(f.gpa, .{ .step = s.word(), .val = part });
    }
    return f.recordOf(place, tmp.items, inst, base);
}

/// Whether location `loc` is a field slot of the record at the root of its layout (`Loc.addSlots`).
fn isOwnSlot(f: *const Frame, loc: u32) bool {
    const t = &f.m.loc;
    if (loc == 0 or t.loc_parent.items[loc] != 0) return false;
    const l: Loc.Label = @bitCast(t.loc_label.items[loc]);
    return l.kind == .fslot and !l.cyc;
}

/// The entry of `place`'s layout that is the slot of field `rank` of the record at `place`, or `none`.
fn slotEntry(f: *Frame, place: PlaceId, rank: u32) Error!u32 {
    const loc = f.m.loc.find(0, Loc.slotLabel(rank, false).word()) orelse return none;
    return f.m.loc.indexOf(try f.m.loc.layoutOf(place), loc);
}

/// The entries of `place`'s layout that are the slots of the fields `ranks`
/// of the record at `place`, or each of its slots when `ranks` is empty.
/// False when one of `ranks` has no slot: the record's type does not name it.
fn slotEntries(f: *Frame, place: PlaceId, ranks: []const u32, out: *std.ArrayList(u32)) Error!bool {
    if (ranks.len == 0) {
        const es = f.m.loc.layoutEntries(try f.m.loc.layoutOf(place));
        // The scan of the layout is work (kernel §8).
        _ = f.charge(Loc.scanUnits(es.len));
        for (es, 0..) |e, k| if (f.isOwnSlot(e.loc)) try out.append(f.gpa, @intCast(k));
        return true;
    }
    _ = f.charge(ranks.len * Loc.lookup_units);
    for (ranks) |rank| {
        const e = try f.slotEntry(place, rank);
        if (e == none) return false;
        try out.append(f.gpa, e);
    }
    return true;
}

/// The atoms of the slots `ranks` of the record `v`, appended to `out`. A
/// value the walk cannot follow, or a slot its type does not name, is all of it.
fn slotAtoms(f: *Frame, v: Val, ranks: []const u32, out: *std.ArrayList(Atom)) Error!void {
    const place = f.placeOfVal(v) orelse {
        if (v == v_outside) try out.append(f.gpa, outside_atom);
        return;
    };
    if (whole(f.nodes.items[v].tag)) {
        _ = try f.leaves(v, 0, out);
        return;
    }
    var es: std.ArrayList(u32) = .empty;
    defer es.deinit(f.gpa);
    if (!try f.slotEntries(place, ranks, &es)) {
        // A slot that the value's own layout does not have (a tuple or a
        // constructor read as a record through `Js.to`, one JavaScript
        // object): no cell of the frame names the object written, so the
        // write has no claim on it (kernel §3.4; research report 147).
        try out.append(f.gpa, outside_atom);
        _ = try f.allLeaves(v, out);
        return;
    }
    for (es.items) |e| _ = try f.leaves(v, e, out);
}

/// The slots `ranks` of the record `v` (each of them, when empty) are read
/// at `point` (kernel §11): a field access, a record pattern, an update's
/// copy. A value the walk cannot follow, or a slot its type does not name,
/// is read whole.
fn readSlots(f: *Frame, v: Val, ranks: []const u32, point: u32) Error!void {
    if (v == v_none or v == v_outside) return;
    const place = f.placeOfVal(v) orelse return;
    if (whole(f.nodes.items[v].tag)) return f.readAll(v, point);
    const start: u32 = @intCast(f.lists.items.len);
    var es: std.ArrayList(u32) = .empty;
    defer es.deinit(f.gpa);
    if (!try f.slotEntries(place, ranks, &es)) return f.readAll(v, point);
    try f.lists.appendSlice(f.gpa, es.items);
    const nmask: u32 = @intCast(f.lists.items.len - start);
    if (nmask == 0) return;
    try f.uses.append(f.gpa, .{ .point = point, .at = f.timeOf(point), .val = try f.cellsNowIn(v), .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = false });
}

/// The step word of a record construction's kid that holds its field slots
/// (`recordOf`). No step of the place graph has it: it is never read as a step.
const slot_kid: u32 = std.math.maxInt(u32);

/// A record this frame makes (kernel §11): a construction of the field
/// values `kids`, and one more kid, the object: a root whose field slots are
/// the frame's own cells (`own`), or, for an update, the slots of `base`
/// under a new name (`version`), since the object is the base's, written.
/// The construction keeps each field value as it is (a `join` keeps its
/// arms), so a record holds what a construction held before it had slots.
fn recordOf(f: *Frame, place: PlaceId, kids: []const Kid, inst: u32, base: Val) Error!Val {
    const m = f.m;
    // Past the budget (kernel §8) the walk builds nothing more: the
    // declaration gave up.
    if (m.steps_over) {
        f.failed = true;
        var made: std.ArrayList(Val) = .empty;
        defer made.deinit(f.gpa);
        for (kids) |k| try made.append(f.gpa, k.val);
        if (base != v_none) try made.append(f.gpa, base);
        return f.unknownOf(place, made.items);
    }
    if (try f.layoutLen(place) == 0) return v_none;
    const root = try f.newRoot(.local, place, inst);
    // The object holds its slots; what a field holds, a cell's contents
    // among it, the construction's kids hold (kernel §13 reads them there).
    f.roots.items[root].cells = false;
    const r = f.roots.items[root];
    const es = m.loc.layoutEntries(r.layout);
    _ = f.charge(Loc.scanUnits(es.len));
    var any_slot = false;
    for (0..es.len) |e| {
        if (!f.isOwnSlot(es[e].loc)) {
            // Not the object's: the construction's kids hold it.
            f.rents.items[r.ent + e] = .{ .kind = .alias };
            continue;
        }
        any_slot = true;
        // The object: the frame's own cell, or the base's under a new name.
        if (base == v_none) continue;
        const start: u32 = @intCast(f.atoms.items.len);
        const dup = try f.leavesAs(base, place, @intCast(e), &f.atoms);
        for (f.atoms.items[start..]) |*a| a.dead = f.timeOf(inst);
        try f.uniqueTail(&f.atoms, start);
        f.rents.items[r.ent + e] = .{ .kind = .version, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = dup };
    }
    try f.deriveLinear(root, null, &.{});
    if (!any_slot) return f.built(place, kids);
    var all: std.ArrayList(Kid) = .empty;
    defer all.deinit(f.gpa);
    try all.appendSlice(f.gpa, kids);
    try all.append(f.gpa, .{ .step = slot_kid, .val = try f.rootVal(root) });
    return f.built(place, all.items);
}

fn binding(f: *Frame, b: u32) Error!void {
    const m = f.m;
    const data = m.datas[b];
    switch (letTag(m.tags[b])) {
        .def => {
            const def = m.bir.extraData(@fromBackingInt(data.lhs), Bir.LetDef);
            const l = f.d.locals_start + def.local;
            // Code that a binding above named is made already (`makeCode`).
            if (m.lframe[l] == f.id) return;
            if (m.lcode[l] != none) return f.makeCode(def.local);
            const v = try f.eval(data.rhs, .bind, false);
            // A `let` that the markup lowering keeps beyond this call
            // (kernel §6.14): the root holds the value and a later call
            // reads it, so it escapes where it is made.
            if (std.sort.binarySearch(u32, m.kept_lets, b, struct {
                fn order(x: u32, y: u32) std.math.Order {
                    return std.math.order(x, y);
                }
            }.order) != null) try f.escape(v, b);
            f.bindLocal(def.local, v);
        },
        .pattern => {
            const v = try f.ev(data.rhs);
            if (f.readsList(data.lhs)) try f.readNoSlots(v, b);
            try f.bindPattern(data.lhs, v);
        },
        .stmt => _ = try f.ev(data.rhs),
        .not_a_binding => f.failed = true,
    }
}

// ---- the order of a `let` ----------------------------------------------------------------
//
// A `let` evaluates its value bindings in written order, and a local
// function is hoisted (language.md §7, backend.md §4). So code can name a
// binding that is written below it: a later local function, or a value
// that it reads only when it runs. What that code holds is then not bound
// where the code is made. Nothing reads it there either: lowering refuses a
// value binding that reads a later value, directly or through code
// (`let_forward_reference`). So:
//
// - In the code's own frame, the later binding is a capture like any other
//   (`capture`), and the contract says what the code does with it.
// - In the frame that binds it, the closure keeps the binding as a `later`
//   slot (`capSlot`), which is the bound value from where it is bound on
//   (`capVal`). A later local function that is named before it is bound is
//   made where it is first needed (`makeCode`): its own captures are bound
//   there, or are `later` slots in their turn.
// - Code that names other code in a cycle (two local functions that call
//   each other) is one group, walked as a recursive group of declarations
//   is: each member names the others as known functions with their
//   contracts so far, and no member captures another (`solveCodes`). So a
//   closure never holds itself through another, and each walk over values
//   ends.
//
// A value that the walk cannot follow is never "holds nothing" (research
// report 112 §2.2, §2.6; report 113 §6).

/// Whether binding `b` of a `let` binds code: a local function, or a value
/// whose right side is a lambda. Nothing runs where either is bound.
fn isCodeBinding(m: *Mod, b: u32) bool {
    if (m.tags[b] != .let_def) return false;
    const def = m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef);
    if (@backingInt(def.params_end) != @backingInt(def.params_start)) return true;
    return m.tags[m.datas[b].rhs] == .lambda;
}

/// The frame enters a `let`: each local that it binds is this frame's, and
/// unbound until its binding runs.
fn enterLet(f: *Frame, let_inst: u32, bindings: []const Inst.Index) Error!void {
    const m = f.m;
    for (bindings) |bi| {
        const b = bi.int();
        switch (letTag(m.tags[b])) {
            .def => f.unbind(m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef).local),
            .pattern => f.unbindPattern(m.datas[b].lhs),
            // A statement binds no local.
            .stmt => {},
            .not_a_binding => f.failed = true,
        }
    }
    if (!m.let_seen.isSet(let_inst)) {
        m.let_seen.set(let_inst);
        try f.findGroups(bindings);
    }
}

fn unbind(f: *Frame, local: u32) void {
    const l = f.d.locals_start + local;
    f.m.lframe[l] = 0;
    f.m.lbinder[l] = f.id;
}

fn unbindPattern(f: *Frame, pat: u32) void {
    // Each node of a pattern is work (kernel §8).
    _ = f.charge(1);
    const m = f.m;
    const data = m.datas[pat];
    switch (patTag(m.tags[pat])) {
        .variable => f.unbind(data.lhs),
        .as => {
            f.unbind(data.rhs);
            f.unbindPattern(data.lhs);
        },
        .tuple, .list => for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| f.unbindPattern(p.int()),
        .spread => f.unbindPattern(data.lhs),
        .ctor => for (m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index)) |p| f.unbindPattern(p.int()),
        .record => for (m.bir.extraSlice(Bir.inlineRange(data), u32)) |local| f.unbind(local),
        // These bind no local.
        .wild, .int, .char, .string, .unit => {},
        .not_a_pattern => f.failed = true,
    }
}

/// The code bindings of one `let`, and its cyclic groups: the code
/// bindings that name each other in a cycle (strongly connected, by the
/// references in their instructions). A binding's instructions are one run,
/// after the binding's own instruction and after the binding before it
/// (`Lower.checkLetOrder` reads the same runs).
fn findGroups(f: *Frame, bindings: []const Inst.Index) Error!void {
    const m = f.m;
    var codes: std.ArrayList([3]u32) = .empty; // binding, first instruction, last instruction
    defer codes.deinit(f.gpa);
    var prev: u32 = 0;
    for (bindings, 0..) |bi, k| {
        const b = bi.int();
        var last = b;
        switch (letTag(m.tags[b])) {
            .def => {
                last = @max(last, m.datas[b].rhs);
                const def = m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef);
                for (m.bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Inst.Index)) |p| last = @max(last, p.int());
            },
            .pattern => last = @max(last, @max(m.datas[b].lhs, m.datas[b].rhs)),
            .stmt => last = @max(last, m.datas[b].rhs),
            .not_a_binding => f.failed = true,
        }
        const first = (if (k == 0) b else @max(prev, b)) + 1;
        prev = @max(prev, last);
        if (!isCodeBinding(m, b)) continue;
        const def = m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef);
        m.lcode[f.d.locals_start + def.local] = b;
        try codes.append(f.gpa, .{ b, first, last });
    }
    if (codes.items.len < 2) return;
    // The edges: which code bindings each one names.
    const n = codes.items.len;
    // Each code binding's index among them, in a column by local, cleared at the end.
    for (codes.items, 0..) |c, i| {
        const def = m.bir.extraData(@fromBackingInt(m.datas[c[0]].lhs), Bir.LetDef);
        m.lindex[f.d.locals_start + def.local] = @intCast(i);
    }
    defer for (codes.items) |c| {
        const def = m.bir.extraData(@fromBackingInt(m.datas[c[0]].lhs), Bir.LetDef);
        m.lindex[f.d.locals_start + def.local] = none;
    };
    var edges: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (edges.items) |*e| e.deinit(f.gpa);
        edges.deinit(f.gpa);
    }
    for (codes.items) |c| {
        var out: std.ArrayList(u32) = .empty;
        var i = c[1];
        while (i <= c[2]) : (i += 1) {
            if (m.tags[i] != .local) continue;
            const j = m.lindex[f.d.locals_start + m.datas[i].lhs];
            if (j != none) try out.append(f.gpa, j);
        }
        try edges.append(f.gpa, out);
    }
    // Tarjan's strongly connected components.
    var t: Tarjan = .{ .gpa = f.gpa, .edges = edges.items };
    defer t.deinit();
    try t.init(n);
    for (0..n) |v| if (t.index[v] == none) try t.visit(@intCast(v));
    for (t.comps.items) |comp| {
        if (comp.len < 2) continue;
        const members = try m.arena.alloc(u32, comp.len);
        for (members, comp) |*mb, ci| mb.* = codes.items[ci][0];
        std.mem.sortUnstable(u32, members, {}, std.sort.asc(u32));
        const gid: u32 = @intCast(m.groups.items.len);
        try m.groups.append(m.gpa, members);
        for (members) |b| {
            const def = m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef);
            m.lgroup[f.d.locals_start + def.local] = gid;
        }
    }
}

const Tarjan = struct {
    gpa: Allocator,
    edges: []const std.ArrayList(u32),
    index: []u32 = &.{},
    low: []u32 = &.{},
    on: []bool = &.{},
    stack: std.ArrayList(u32) = .empty,
    comps: std.ArrayList([]const u32) = .empty,
    next: u32 = 0,

    fn init(t: *Tarjan, n: usize) Error!void {
        t.index = try t.gpa.alloc(u32, n);
        @memset(t.index, none);
        t.low = try t.gpa.alloc(u32, n);
        t.on = try t.gpa.alloc(bool, n);
        @memset(t.on, false);
    }

    fn deinit(t: *Tarjan) void {
        t.gpa.free(t.index);
        t.gpa.free(t.low);
        t.gpa.free(t.on);
        t.stack.deinit(t.gpa);
        for (t.comps.items) |c| t.gpa.free(c);
        t.comps.deinit(t.gpa);
    }

    fn visit(t: *Tarjan, v: u32) Error!void {
        t.index[v] = t.next;
        t.low[v] = t.next;
        t.next += 1;
        try t.stack.append(t.gpa, v);
        t.on[v] = true;
        for (t.edges[v].items) |w| {
            if (t.index[w] == none) {
                try t.visit(w);
                t.low[v] = @min(t.low[v], t.low[w]);
            } else if (t.on[w]) t.low[v] = @min(t.low[v], t.index[w]);
        }
        if (t.low[v] != t.index[v]) return;
        var comp: std.ArrayList(u32) = .empty;
        while (true) {
            const w = t.stack.pop().?;
            t.on[w] = false;
            try comp.append(t.gpa, w);
            if (w == v) break;
        }
        try t.comps.append(t.gpa, try comp.toOwnedSlice(t.gpa));
    }
};

/// One code to walk: a local function, a lambda bound to a local, or a lambda.
const Member = struct {
    inst: u32,
    params: []const Inst.Index,
    body: u32,
    ty: Var.Optional,
    /// The local that the code is bound to, or `none`.
    local: u32 = none,
};

fn memberOf(f: *Frame, b: u32) Member {
    const m = f.m;
    const data = m.datas[b];
    const def = m.bir.extraData(@fromBackingInt(data.lhs), Bir.LetDef);
    if (@backingInt(def.params_end) != @backingInt(def.params_start)) {
        const params = m.bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Inst.Index);
        return .{ .inst = b, .params = params, .body = data.rhs, .ty = m.typeOfLocal(f.d, def.local), .local = def.local };
    }
    const lam = data.rhs;
    const params = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(m.datas[lam].lhs)), Inst.Index);
    return .{ .inst = lam, .params = params, .body = m.datas[lam].rhs, .ty = m.typeOfInst(lam), .local = def.local };
}

/// Make the code bound to `local` in this frame, with the rest of its
/// group, and bind it.
fn makeCode(f: *Frame, local: u32) Error!void {
    const m = f.m;
    const l = f.d.locals_start + local;
    if (m.lframe[l] == f.id) return;
    const one = [1]u32{m.lcode[l]};
    const bs: []const u32 = if (m.lgroup[l] != none) m.groups.items[m.lgroup[l]] else &one;
    const ms = try f.gpa.alloc(Member, bs.len);
    for (ms, bs) |*mb, b| mb.* = f.memberOf(b);
    const vals = try f.solveCodes(ms);
    for (ms, vals) |mb, v| f.bindLocal(mb.local, v);
}

fn caseOf(f: *Frame, inst: u32, mode: Mode, tail: bool) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    const scrut = try f.ev(data.lhs);
    const branches = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index);
    // A list pattern reads the list, before any branch runs.
    for (branches) |br| if (f.readsList(m.datas[br.int()].lhs)) {
        try f.readNoSlots(scrut, data.lhs);
        break;
    };
    var outs: std.ArrayList(Val) = .empty;
    defer outs.deinit(f.gpa);
    var ctxs: std.ArrayList(u32) = .empty;
    defer ctxs.deinit(f.gpa);
    // The cells' versions before the arms, and after each (kernel §13).
    const cells0 = try f.saveCells();
    var arm_cells: std.ArrayList([]const [2]u32) = .empty;
    defer arm_cells.deinit(f.gpa);
    for (branches, 0..) |br, k| {
        const bd = m.datas[br.int()];
        if (cells0) |c0| if (k != 0) {
            try f.restoreCells(c0);
        };
        const saved = try f.enterArm(inst, @intCast(k));
        try ctxs.append(f.gpa, f.cur_ctx);
        try f.bindPattern(bd.lhs, scrut);
        try outs.append(f.gpa, try f.eval(bd.rhs, if (mode == .bind) .value else mode, tail));
        if (cells0 != null) {
            try f.flushShare();
            try arm_cells.append(f.gpa, (try f.saveCells()).?);
        }
        f.cur_ctx = saved;
    }
    if (cells0 != null and arm_cells.items.len != 0) try f.joinCells(arm_cells.items, ctxs.items);
    return f.joinVal(try m.placeOfInst(inst), outs.items, ctxs.items);
}

// ---- lambdas and local functions -------------------------------------------------------

/// Walk the code at `inst` in its own frame, to its contract; the value is a closure over its captures.
fn codeValue(f: *Frame, inst: u32, params: []const Inst.Index, body: u32, ty: Var.Optional, self_local: u32) Error!Val {
    const one = [1]Member{.{ .inst = inst, .params = params, .body = body, .ty = ty, .local = self_local }};
    const vals = try f.solveCodes(&one);
    return vals[0];
}

/// Walk the codes `ms`, each in its own frame, to their contracts, and make
/// a closure of each. A code bound to a local can name itself, and the
/// members of a group name each other: each such name is the known function
/// with its contract so far (`memberValue`). The rounds start from the
/// contract with no flag and no source and run until no contract changes,
/// as a group of declarations does.
fn solveCodes(f: *Frame, ms: []const Member) Error![]Val {
    const m = f.m;
    // Each code is walked here, in its own frame (rule 3).
    for (ms) |mb| f.noteWalked(mb.inst);
    const caps = try f.gpa.alloc([]const u32, ms.len);
    @memset(caps, &.{});
    const vals = try f.gpa.alloc(Val, ms.len);
    // Read only where the walk gives up on the whole declaration (below).
    @memset(vals, v_outside);
    // Past the budget (kernel §8) no code is walked or joined any more: the
    // declaration gave up.
    if (m.steps_over) {
        f.failed = true;
        return vals;
    }
    for (ms) |mb| {
        const fnt = m.fnType(mb.ty);
        const pvars: []const Var = if (fnt) |ft| m.in.store.vars(ft.params) else &.{};
        // A contract of an earlier walk of the declaration (a round of its
        // group) is where the rounds start, and a draft while they run, as a
        // bottom one is: a fresh cell of it is named by its call alone
        // (`freshAtom`). Read as a finished contract, the cells of its own
        // calls would have new names in each walk, and the group would never
        // settle (research report 138).
        if (m.code_contract[mb.inst]) |c| try m.drafts.put(m.gpa, @intFromPtr(c), {});
        if (mb.local == none or m.code_contract[mb.inst] != null or pvars.len != mb.params.len) continue;
        const places = try f.gpa.alloc(PlaceId, mb.params.len);
        const tys = try f.gpa.alloc(Var.Optional, mb.params.len);
        for (places, tys, pvars) |*p, *t, pv| {
            p.* = try m.placeOf(pv.toOptional());
            t.* = pv.toOptional();
        }
        m.code_contract[mb.inst] = try m.bottomContract(places, tys, try m.placeOf(fnt.?.result.toOptional()));
        try m.drafts.put(m.gpa, @intFromPtr(m.code_contract[mb.inst].?), {});
        m.code_caps[mb.inst] = &.{};
    }
    const mark = m.lines.items.len;
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        // The codes are in work: a name of one is the code with its contract so far.
        for (ms) |mb| if (mb.local != none) {
            m.lv[f.d.locals_start + mb.local] = v_none;
            m.lframe[f.d.locals_start + mb.local] = none;
        };
        for (ms) |mb| m.recalled[mb.inst] = false;
        var changed = false;
        for (ms, 0..) |mb, i| {
            const fnt = m.fnType(mb.ty);
            const pvars: []const Var = if (fnt) |ft| m.in.store.vars(ft.params) else &.{};
            if (m.steps_over) {
                f.failed = true;
                return vals;
            }
            var child = try Frame.init(m, f, f.decl, true, mb.inst);
            child.own_params = @intCast(mb.params.len);
            if (child.depth > 200) {
                f.failed = true;
                return vals;
            }
            for (mb.params, 0..) |p, k| {
                const place = if (k < pvars.len) try m.placeOf(pvars[k].toOptional()) else m.var_place;
                try child.addParam(place, p.int(), if (k < pvars.len) pvars[k].toOptional() else .none);
            }
            try child.walkBody(mb.body);
            // Past the budget no walk goes on (kernel §8).
            if (m.steps_over) {
                f.failed = true;
                return vals;
            }
            const rplace = if (fnt) |ft| try m.placeOf(ft.result.toOptional()) else m.var_place;
            const c = try child.finish(rplace);
            if (child.failed) f.failed = true;
            caps[i] = try f.gpa.dupe(u32, child.cap_locals.items);
            const old = m.code_contract[mb.inst];
            const joined = if (old) |o| try CMod.join(m.arena, o, c) else c;
            if (if (old) |o| !CMod.eql(o, joined) else true) changed = true;
            m.code_contract[mb.inst] = joined;
            m.code_caps[mb.inst] = try m.arena.dupe(u32, caps[i]);
            // A draft while the rounds run: a fresh cell of it is named by its call alone (`freshAtom`).
            try m.drafts.put(m.gpa, @intFromPtr(joined), {});
        }
        // A code that names itself or a member of its group is walked again until the contracts hold.
        var again = false;
        for (ms) |mb| if (m.recalled[mb.inst]) {
            again = true;
        };
        if (!changed or !again or rounds > 16) {
            if (rounds > 16) f.failed = true;
            break;
        }
        m.lines.shrinkRetainingCapacity(mark);
    }
    for (ms) |mb| if (m.code_contract[mb.inst]) |c| {
        _ = m.drafts.remove(@intFromPtr(c));
    };
    for (ms, 0..) |mb, i| vals[i] = try f.closureOf(mb, caps[i]);
    return vals;
}

/// The closure of the walked code `mb`: its contract, and the captured
/// locals as this frame has them.
fn closureOf(f: *Frame, mb: Member, cap_locals: []const u32) Error!Val {
    const m = f.m;
    const c = m.code_contract[mb.inst].?;
    var tmp: std.ArrayList(Val) = .empty;
    defer tmp.deinit(f.gpa);
    for (cap_locals) |l| try tmp.append(f.gpa, try f.capSlot(l));
    // A closure runs where its holder runs it: each use of it reads, writes
    // and renews what it captured (`apply`, `flowCode`), and a holder that
    // the walk does not follow shares each handle it captured (kernel §13
    // items 8 and 11). A closure in a hole of markup runs where the markup
    // renders (§6.12): each handle it captured has another holder now.
    if (f.markup_reads != null) for (tmp.items) |v| if (f.nodes.items[v].tag != .later) try f.shareVal(v, mb.inst);
    const start: u32 = @intCast(f.lists.items.len);
    try f.lists.appendSlice(f.gpa, tmp.items);
    try f.codes.append(f.gpa, .{ .contract = c, .caps = start, .ncaps = @intCast(cap_locals.len), .inst = mb.inst, .own_params = @intCast(mb.params.len) });
    const v = try f.node(.{ .tag = .closure, .place = try m.placeOf(mb.ty), .a = @intCast(f.codes.items.len - 1) });
    // A closure made in a hole of markup reads what it captured where the
    // lowering evaluates the hole, which can be where it renders (kernel
    // §6.12): the markup holds the closure, so it holds each capture.
    if (f.markup_reads) |mr| try mr.append(f.gpa, v);
    return v;
}

/// What a closure that this frame makes holds of the captured local `local`:
/// its value; a capture of this frame; or, for a binding of this frame that
/// is not bound yet (code in work, or a later binding of its `let`), a
/// `later` slot that `capVal` reads as the value bound there.
fn capSlot(f: *Frame, local: u32) Error!Val {
    const m = f.m;
    const l = f.d.locals_start + local;
    if (m.lframe[l] == f.id) return m.lv[l];
    if (m.lbinder[l] == f.id) return f.node(.{ .tag = .later, .place = try m.placeOfLocal(f.d, local), .a = local });
    return f.capture(local);
}

/// Captured value `k` of the known function `code`. A `later` slot is the
/// value that the frame binds there; a later code binding that is needed
/// before it is bound is made now (what it reads is bound, by lowering's
/// order rule). A slot that is not bound where it is read is a value that
/// lowering would refuse there: the walk gives up.
fn capVal(f: *Frame, code: Code, k: usize) Error!Val {
    const m = f.m;
    const i = code.caps + k;
    const v = f.lists.items[i];
    const n = f.nodes.items[v];
    // A captured handle is read where the code runs: at its latest version
    // (kernel §13 items 5 and 11). No share is made here: the caller may
    // be making a run of `f.atoms`.
    if (n.tag != .later) return f.cellsNowIn(v);
    const l = f.d.locals_start + n.a;
    if (m.lframe[l] == 0 and m.lcode[l] != none) try f.makeCode(n.a);
    if (m.lframe[l] != f.id) {
        f.failed = true;
        return f.unknownOf(n.place, &.{});
    }
    if (safety) std.debug.assert(m.lv[l] != v_unbound);
    f.lists.items[i] = m.lv[l];
    return f.cellsNowIn(m.lv[l]);
}

/// The frame's contract, once its body is walked.
/// Whether a cell of a parameter can be at two locations of `v` read at
/// `place` (`rn` entries): one of a join's values at a time, since a run
/// answers one of them (kernel §4.4, *One value of a join at a time*), and
/// any other value by its runs. Only two entries that each hold an atom can
/// share one: each pair of them costs its comparisons (`dupOverlap`, kernel
/// §8), and past the budget the answer is yes. A join nested deeper than 8
/// is tested whole, the merged runs of its values: a superset of each.
fn atTwoLocations(f: *Frame, v: Val, place: PlaceId, rn: usize, depth: u32) Error!bool {
    if (v == v_none) return false;
    const n = f.nodes.items[v];
    if (n.tag == .join and depth < 8) {
        for (0..n.b) |ki| if (try f.atTwoLocations(f.lists.items[n.a + 2 * ki], place, rn, depth + 1)) return true;
        return false;
    }
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    var all: std.ArrayList(Atom) = .empty;
    defer all.deinit(f.gpa);
    _ = f.charge(rn);
    for (0..rn) |e| {
        const start: u32 = @intCast(all.items.len);
        _ = try f.leavesAs(v, place, @intCast(e), &all);
        try f.uniqueTail(&all, start);
        try runs.append(f.gpa, .{ start, @intCast(all.items.len) });
    }
    return f.runsTwice(all.items, runs.items);
}

/// Whether one cell is in two of `runs` of `all`, the runs of a value's
/// entries. Only two entries that each hold an atom can share one: each
/// pair of them costs its comparisons (`dupOverlap`, kernel §8), and past
/// the budget the answer is yes. The test stops at the first pair that
/// shares a cell; a large set is tested by `runsShare`, linear in its atoms.
fn runsTwice(f: *Frame, all: []const Atom, runs: []const [2]u32) Error!bool {
    var held: std.ArrayList(u32) = .empty;
    defer held.deinit(f.gpa);
    for (runs, 0..) |r, e| if (r[1] > r[0]) try held.append(f.gpa, @intCast(e));
    if (all.len > share_small) return f.runsShare(all, runs, null);
    if (held.items.len > 1) try f.checkShare(all, runs, null);
    for (held.items, 0..) |e1, i| {
        for (held.items[i + 1 ..]) |e2| {
            if (f.dupOverlap(all[runs[e1][0]..runs[e1][1]], all[runs[e2][0]..runs[e2][1]])) return true;
        }
    }
    return false;
}

pub fn finish(f: *Frame, result_place: PlaceId) Error!*const Contract {
    const m = f.m;
    try f.flushShare();
    try f.revokeWriters();
    try f.cellReads();
    try f.finishDemands();
    try f.finishProbes();
    f.finished = true;
    // What the body reads of each parameter.
    var tmp: std.ArrayList(Atom) = .empty;
    defer tmp.deinit(f.gpa);
    for (f.uses.items) |u| {
        tmp.clearRetainingCapacity();
        if (u.all) {
            _ = try f.allLeaves(u.val, &tmp);
        } else for (0..u.nmask) |i| {
            _ = try f.leaves(u.val, f.lists.items[u.mask + i], &tmp);
        }
        // The frame's answer, read where it is answered, answers a field
        // slot of a parameter: no read of it at the call (`flag_a`).
        for (tmp.items) |a| try f.markAtom(a, if (u.tail and f.isSlotAtom(a)) flag_a else flag_r);
    }
    const arity: u32 = @intCast(f.params.items.len);
    const layouts = try m.arena.alloc(u32, arity + 1);
    const off = try m.arena.alloc(u32, arity + 1);
    var total: u32 = 0;
    for (f.params.items, 0..) |root, k| {
        layouts[k] = f.roots.items[root].layout;
        off[k] = total;
        total += @intCast(m.loc.layouts.items[layouts[k]].len);
    }
    off[arity] = total;
    layouts[arity] = try m.loc.layoutOf(result_place);
    const flags = try m.arena.alloc(u8, total);
    for (f.params.items, 0..) |root, k| {
        const r = f.roots.items[root];
        const n = m.loc.layouts.items[r.layout].len;
        @memcpy(flags[off[k]..][0..n], f.pflags.items[r.ent..][0..n]);
    }
    // The result: what each of its locations is made of.
    const rn = m.loc.layouts.items[layouts[arity]].len;
    const res = try m.arena.alloc([]const Src, rn);
    const result = try f.joinVal(result_place, f.returns.items, &.{});
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    var all: std.ArrayList(Atom) = .empty;
    defer all.deinit(f.gpa);
    var dups: std.ArrayList(bool) = .empty;
    defer dups.deinit(f.gpa);
    // Each entry of the result is a step (kernel §8).
    _ = f.charge(rn);
    for (0..rn) |e| {
        const start: u32 = @intCast(all.items.len);
        const dup = if (result == v_none) false else try f.leavesAs(result, result_place, @intCast(e), &all);
        try f.uniqueTail(&all, start);
        try runs.append(f.gpa, .{ start, @intCast(all.items.len) });
        try dups.append(f.gpa, dup);
    }
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    // Each atom of the result is a step (kernel §8).
    _ = f.charge(all.items.len);
    for (0..rn) |e| {
        srcs.clearRetainingCapacity();
        const mine = all.items[runs.items[e][0]..runs.items[e][1]];
        // One cell at two places of a summary location: the location keeps
        // its claim, and its parts are not apart (kernel §4.4).
        const twice = dups.items[e] and !m.loc.layoutEntries(layouts[arity])[e].single;
        // Each atom is a named source (kernel §4.2): a cell the frame made
        // is `fresh(k)`, with its escape, so one cell at two entries is one
        // `k` at two entries, and an escaped cell is escaped where the caller reads it.
        f.newVisit();
        for (mine) |a| try f.atomSrcsIn(a, &srcs);
        if (twice) try srcs.append(f.gpa, Src.twice);
        res[e] = try CMod.normal(m.arena, srcs.items);
        if (safety and result != v_none and !m.steps_over) {
            // `twice` names no cell: a location with no other source holds none.
            const names = for (res[e]) |x| {
                if (x.kind != .twice) break true;
            } else false;
            if (!names) try f.checkEmpty(result, result_place, @intCast(e));
        }
        // An answered location is answered, and so another operand of a
        // call that writes (kernel §5, test 2). It is read too, except a
        // record's field slot: the caller holds the answer and reads the
        // slot where it reads it (kernel §11).
        for (res[e]) |s| if (s.kind == .param) {
            flags[off[s.a] + s.e] |= flag_a;
            if (m.loc.layoutEntries(layouts[s.a])[s.e].kind != .field) flags[off[s.a] + s.e] |= flag_r;
        };
    }
    // The function parameters. Each parameter of a function type has a
    // contract, also when the body does nothing with it: a missing fact
    // about a function is never "nothing happens" (research report 112 §2.2).
    const fns = try m.arena.alloc(?*const CMod.Fn, arity);
    @memset(fns, null);
    for (f.params.items) |root| if (f.isFnRoot(root)) {
        _ = try f.draftOf(root, null);
    };
    for (f.drafts.items) |*dr| {
        const idx = f.roots.items[dr.root].index;
        const supply = try m.arena.alloc([]const Src, dr.supply.len);
        for (supply, dr.supply) |*s, l| {
            s.* = try CMod.normal(m.arena, l.items);
            for (s.*) |x| if (x.kind == .param) {
                flags[off[x.a] + x.e] |= flag_r;
            };
        }
        for (supply, dr.free) |s, free| if (free) for (s) |x| if (x.kind == .param) {
            flags[off[x.a] + x.e] |= flag_s;
        };
        const fnc = try m.arena.create(CMod.Fn);
        fnc.* = .{ .arity = dr.arity, .layouts = dr.layouts, .off = dr.off, .supply = supply, .free = try m.arena.dupe(bool, dr.free), .called = dr.called, .lost = dr.lost, .ans_escapes = dr.ans_escapes, .rewrites = dr.rewrites };
        fns[idx] = fnc;
        // The function itself is used.
        if (dr.used) for (flags[off[idx]..off[idx + 1]]) |*x| {
            x.* |= flag_r;
        };
    }
    // Whether a cell of a parameter can be at two locations of the result,
    // on the runs read above (`runsTwice`). Where they say so and the result
    // is a join, each of its values is asked on its own: the result is one
    // of them at a time (kernel §4.4, *One value of a join at a time*), so
    // a cell at one location in one value and at another in another is at
    // one place of each.
    var nonlinear = try f.runsTwice(all.items, runs.items);
    if (nonlinear and result != v_none and f.nodes.items[result].tag == .join) nonlinear = try f.atTwoLocations(result, result_place, rn, 0);
    for (dups.items) |d| if (d) {
        nonlinear = true;
    };
    // Which edges of its calls can see a cell of the contract (kernel §6
    // rule 10): no step, so no limit depends on it.
    try f.judgeJsSites(result);
    // What the body leaves in its parameters' cells (kernel §13).
    const renew = try f.publishRenew(flags, off, total);
    const c = try m.arena.create(Contract);
    c.* = .{ .arity = arity, .layouts = layouts, .off = off, .flags = flags, .res = res, .fns = fns, .nonlinear = nonlinear, .old_result = f.tail_old, .casts = f.casts, .exact = f.answersParam0(), .switches = f.switched, .renew = renew };
    return c;
}

/// Safe builds: a location of a published result with no source holds no
/// cell by a rule, not because the reading had no step for it (kernel §3.4,
/// §9). Where the result's own layout is coarser than the result's type, the
/// entry of the own layout that holds the location's cells (a wide entry
/// above it, `Loc.holes`) holds no atom either.
fn checkEmpty(f: *Frame, v: Val, place: PlaceId, e: u32) Error!void {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .ref, .built, .join => {},
        .none, .fnref, .outside, .closure, .unknown => return,
        .later => unreachable, // read through `capVal` only
    }
    if (n.place == place) return;
    const m = f.m;
    const view = try m.loc.layoutOf(place);
    const own = try m.loc.layoutOf(n.place);
    if (view == own) return;
    const up = try m.loc.cover(own, view);
    const k = up[e];
    if (k >= Loc.all or !m.loc.layoutEntries(own)[k].kind.wide()) return;
    var tmp: std.ArrayList(Atom) = .empty;
    defer tmp.deinit(f.gpa);
    // The check counts nothing: a safe build's budget is a release build's.
    const steps = m.steps;
    const units = m.module_units;
    const over = m.steps_over;
    const failed = f.failed;
    _ = try f.leavesOwn(v, &.{k}, &tmp);
    m.steps = steps;
    m.module_units = units;
    m.steps_over = over;
    f.failed = failed;
    if (tmp.items.len != 0) std.debug.panic("own3: result location {d} of a contract has no source, and the wide entry {d} above it holds {d} cells (kernel §3.4)", .{ e, k, tmp.items.len });
}

/// What atom `a` is for a contract: a parameter location, a named fresh
/// cell, an outside cell, an answer (kernel §4.2). Each entry of a run once
/// (`markAtom`).
fn atomSrcs(f: *Frame, a: Atom, out: *std.ArrayList(Src)) Error!void {
    f.newVisit();
    return f.atomSrcsIn(a, out);
}

/// `atomSrcs` with the entries that the visit in progress reached skipped. The
/// runs are walked with no recursion, each entry and atom counted (kernel
/// §8); past the budget the walk stops, and the declaration gives up.
fn atomSrcsIn(f: *Frame, a: Atom, out: *std.ArrayList(Src)) Error!void {
    f.mark_stack.clearRetainingCapacity();
    try f.mark_stack.append(f.gpa, a);
    while (f.mark_stack.pop()) |x| {
        const r = f.roots.items[x.root];
        switch (r.kind) {
            .outside => try out.append(f.gpa, Src.outside),
            .param, .capture => try out.append(f.gpa, .{ .kind = .param, .a = @intCast(r.index), .e = @intCast(x.e), .p = try f.posSrc(x) }),
            .answer => try out.append(f.gpa, .{ .kind = .answer, .a = @intCast(f.roots.items[f.drafts.items[r.index].root].index), .e = @intCast(x.e) }),
            // A cell a callee made is a cell this frame made, for its caller.
            .fresh => try out.append(f.gpa, try f.freshSrc(x)),
            .local => {
                const ent = f.rents.items[r.ent + x.e];
                switch (ent.kind) {
                    // A new name of cells that exist: its sources are theirs. The
                    // run of `alias` and `derived` is in the list on its own
                    // (`rootLeaves` puts it there).
                    .taken, .version => {
                        if (try f.visited(x)) continue;
                        if (f.charge(1 + ent.len)) return;
                        try f.mark_stack.appendSlice(f.gpa, f.atoms.items[ent.start..][0..ent.len]);
                    },
                    .alias => {},
                    // A cell the frame made.
                    .own, .derived => try out.append(f.gpa, try f.freshSrc(x)),
                }
            },
        }
    }
}

/// `Src.p` of a parameter's atom `x` (kernel §6 rule 10, *A position*): the
/// atom was read at a position of a match of `posKey` whose list is that
/// parameter whole, read at no position, whose index is the local that
/// another parameter's pattern binds, and the atom is at or below an element
/// of that list. Then its caller can read it at the same position of its own
/// arguments. Else 0.
fn posSrc(f: *Frame, x: Atom) Error!u8 {
    if (x.pos == none or f.pos_info.items.len == 0) return 0;
    // The scan of the frame's matches is work (kernel §8).
    if (f.charge(Loc.scanUnits(f.pos_info.items.len))) return 0;
    const key = for (f.pos_info.items) |k| {
        if (k[0] == x.pos >> pos_bits) break k[1..5].*;
    } else return 0;
    const r = f.roots.items[x.root];
    if (key[0] != x.root or r.kind != .param or key[1] != r.path or key[2] != none) return 0;
    const pr = (try f.m.loc.proj(r.place, Step.elem)) orelse return 0;
    // The scans are work (kernel §8).
    if (f.charge(Loc.scanUnits(pr.up.len) + f.params.items.len)) return 0;
    if (std.mem.indexOfScalar(u32, pr.up, x.e) == null) return 0;
    for (f.params.items, 0..) |root, q| {
        const pat = f.roots.items[root].inst;
        if (pat != none and f.m.tags[pat] == .pat_var and f.m.datas[pat].lhs == key[3]) return Src.posOf(q, x.pos & ((1 << pos_bits) - 1));
    }
    return 0;
}

/// The source of the own cell that atom `a` names: its allocation site in
/// this frame's contract, and whether the frame let it escape.
fn freshSrc(f: *Frame, a: Atom) Error!Src {
    const k = try f.freshId(a.root, a.e);
    // The escapes that an earlier question about the same cell tested are
    // not tested again: one result location of a wide layout can hold the
    // same cells as each of the others, and each asks. A known answer costs
    // a lookup, and never more than the scan it replaces (kernel §8).
    const got = try f.fresh_esc.getOrPut(f.gpa, .{ a.root, a.path, a.e });
    if (!got.found_existing) got.value_ptr.* = .{ 0, 0, 0 };
    const memo = got.value_ptr;
    if (memo[0] != 0) _ = f.charge(@min(Loc.lookup_units, memo[2]));
    var escaped = memo[1] != 0;
    for (f.escapes.items[memo[0]..]) |esc| {
        if (escaped) {
            // The answer is known; the rest of the scan only counts.
            _ = f.charge(esc.len);
        } else if (f.overlapAny(&.{a}, f.esc_atoms.items[esc.start..][0..esc.len])) escaped = true;
        memo[2] += esc.len;
    }
    memo[0] = @intCast(f.escapes.items.len);
    memo[1] = @intFromBool(escaped);
    return Src.fresh(k, escaped);
}

// ---- cells (kernel §13) ---------------------------------------------------------------
//
// A cell's contents are locations below its handle (`◆`). The frame follows
// them for a root it can name every holder of: a parameter, the answer of a
// call that holds new cells' handles and nothing else, and a version of one
// (`Root.tracked`). A call that stores into a cell renews its contents
// (`Contract.renew`): the frame makes a new **version** of the root, whose
// contents are what the call left there, and from then on every reading of
// the root is a reading of that version (`cellsNow`). A value taken out of
// the cell before (a loan, `Ref.get`'s answer) is a root of its own: it holds
// the old contents. A handle that gets another holder (a closure, an escape, a
// copy in another root, a function the frame does not know) is **shared**: its
// contents escape, and from then on hold `outside` as well (`shareCell`).

/// Per entry of `layout`, whether it is in a cell's contents, below a
/// handle; empty when the layout has no handle. A handle in the deep level
/// of a cycle names its contents by no label path apart from the cycle's
/// other members: each other entry of its layout is read as its contents
/// (the pessimistic side). Made once for each layout; each pair of a handle
/// and an entry is work (kernel §8).
fn innerOf(f: *Frame, layout: u32) Error![]const bool {
    if (layout < f.cell_inner.items.len) if (f.cell_inner.items[layout]) |x| return x;
    if (layout >= f.cell_inner.items.len) try f.cell_inner.appendNTimes(f.gpa, null, layout + 1 - f.cell_inner.items.len);
    const m = f.m;
    const es = m.loc.layoutEntries(layout);
    const any = for (es) |e| {
        if (e.kind == .cell) break true;
    } else false;
    if (!any) {
        f.cell_inner.items[layout] = &.{};
        return &.{};
    }
    const out = try f.gpa.alloc(bool, es.len);
    @memset(out, false);
    for (es, 0..) |h, hi| if (h.kind == .cell) {
        _ = f.charge(es.len);
        const deep = try f.deepLoc(h.loc);
        for (es, 0..) |e, k| if (k != hi and (deep or m.loc.isPrefix(h.loc, e.loc))) {
            out[k] = true;
        };
    };
    f.cell_inner.items[layout] = out;
    return out;
}

/// Whether atom `a` of a capture root is in the contents of a cell the
/// frame follows (kernel §13 item 11): a write there is judged where the
/// code runs, as a parameter's is.
fn captureContents(f: *Frame, a: Atom) Error!bool {
    const r = f.roots.items[a.root];
    if (r.kind != .capture or !r.tracked) return false;
    const inner = try f.innerOf(r.layout);
    return a.e < inner.len and inner[a.e];
}

/// Whether the location `loc` is in the deep level of a cycle.
fn deepLoc(f: *Frame, loc: u32) Error!bool {
    var ls: std.ArrayList(u64) = .empty;
    defer ls.deinit(f.gpa);
    try f.m.loc.labels(loc, &ls, f.gpa);
    for (ls.items) |w| if (@as(Loc.Label, @bitCast(w)).cyc) return true;
    return false;
}

/// The entries of `layout` in the contents of the handle at entry `h`.
fn contentsAt(f: *Frame, layout: u32, h: u32, out: *std.ArrayList(u32)) Error!void {
    const m = f.m;
    const es = m.loc.layoutEntries(layout);
    const deep = try f.deepLoc(es[h].loc);
    _ = f.charge(es.len);
    for (es, 0..) |e, k| if (k != h and (deep or m.loc.isPrefix(es[h].loc, e.loc))) try out.append(f.gpa, @intCast(k));
}

/// The tracked root that root `root` is a version of, or itself.
fn originOf(f: *const Frame, root: u32) u32 {
    const o = f.roots.items[root].origin;
    return if (o != none) o else root;
}

/// `v` with each part of a tracked root read at that root's latest version
/// (kernel §13): the reading of a value now. A part that is no root's (a
/// construction, a join) is read part by part.
fn cellsNow(f: *Frame, v: Val) Error!Val {
    try f.flushShare();
    return f.cellsNowIn(v);
}

fn cellsNowIn(f: *Frame, v: Val) Error!Val {
    if (f.cell_roots.items.len == 0 or v == v_none or v == v_outside) return v;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .ref => {
            if (!f.roots.items[n.a].tracked) return v;
            const l = f.latestOf(f.originOf(n.a)) orelse return v;
            return f.reroot(l, n.b);
        },
        .built => {
            if (f.charge(n.b)) return v;
            const kids = try f.gpa.dupe(Kid, f.kids.items[n.a..][0..n.b]);
            var changed = false;
            for (kids) |*k| {
                const nv = try f.cellsNowIn(k.val);
                if (nv != k.val) changed = true;
                k.val = nv;
            }
            if (!changed) return v;
            const start: u32 = @intCast(f.kids.items.len);
            try f.kids.appendSlice(f.gpa, kids);
            return f.node(.{ .tag = .built, .place = n.place, .a = start, .b = n.b });
        },
        .join => {
            if (f.charge(n.b)) return v;
            const arms = try f.gpa.dupe(u32, f.lists.items[n.a..][0 .. 2 * n.b]);
            var changed = false;
            for (0..n.b) |ki| {
                const nv = try f.cellsNowIn(arms[2 * ki]);
                if (nv != arms[2 * ki]) changed = true;
                arms[2 * ki] = nv;
            }
            if (!changed) return v;
            const start: u32 = @intCast(f.lists.items.len);
            try f.lists.appendSlice(f.gpa, arms);
            return f.node(.{ .tag = .join, .place = n.place, .a = start, .b = n.b });
        },
        // No part of a tracked root by a path: a function, outside, or a
        // value of no claim, which `unknownOf` made with its handles shared.
        .none, .outside, .fnref, .closure, .unknown => return v,
        .later => unreachable, // read through `capVal` only
    }
}

/// The latest value `l` of a root (a `ref` of a version, or a `join` of
/// them), read at the path `path` below the root: the versions of one root
/// have its place and layout, so a path of it is a path of each.
fn reroot(f: *Frame, l: Val, path: u32) Error!Val {
    const n = f.nodes.items[l];
    switch (n.tag) {
        .ref => return f.refVal(n.a, path),
        .join => {
            const arms = try f.gpa.dupe(u32, f.lists.items[n.a..][0 .. 2 * n.b]);
            for (0..n.b) |ki| arms[2 * ki] = try f.reroot(arms[2 * ki], path);
            const start: u32 = @intCast(f.lists.items.len);
            try f.lists.appendSlice(f.gpa, arms);
            return f.node(.{ .tag = .join, .place = f.m.loc.paths.items[path].place, .a = start, .b = n.b });
        },
        .none, .outside, .fnref, .closure, .unknown, .built => return l,
        .later => unreachable, // read through `capVal` only
    }
}

/// A new version of the tracked root `o`, whose value now is `cur`: each
/// entry holds what `cur` holds there. The caller renews the entries of the
/// contents it stores into, then derives `linear` (`finishVersion`).
fn versionOf(f: *Frame, o: u32, cur: Val, inst: u32) Error!u32 {
    const m = f.m;
    const place = f.roots.items[o].place;
    const v = try f.newRoot(.local, place, inst);
    f.roots.items[v].tracked = true;
    f.roots.items[v].origin = o;
    const ent0 = f.roots.items[v].ent;
    const es = m.loc.layoutEntries(f.roots.items[v].layout);
    for (es, 0..) |e, k| {
        const start: u32 = @intCast(f.atoms.items.len);
        const dup = try f.leavesAs(cur, place, @intCast(k), &f.atoms);
        try f.uniqueTail(&f.atoms, start);
        f.rents.items[ent0 + k] = .{ .kind = .alias, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = !e.single and (dup or f.curTwice(cur, @intCast(k))) };
    }
    return v;
}

/// Whether entry `k` of a tracked root's value `cur` is `twice` in a root it reads.
fn curTwice(f: *const Frame, cur: Val, k: u32) bool {
    const n = f.nodes.items[cur];
    switch (n.tag) {
        .ref => {
            const r = f.roots.items[n.a];
            return r.kind == .local and f.rents.items[r.ent + k].twice;
        },
        .join => {
            for (0..n.b) |ki| if (f.curTwice(f.lists.items[n.a + 2 * ki], k)) return true;
            return false;
        },
        .none, .outside, .fnref, .closure, .unknown, .built, .later => return false,
    }
}

/// `linear` of a version, from its atoms; it is the root's latest from now on.
fn finishVersion(f: *Frame, o: u32, v: u32) Error!void {
    const n = f.m.loc.layouts.items[f.roots.items[v].layout].len;
    const answers = try f.gpa.alloc(bool, n);
    @memset(answers, false);
    try f.deriveLinear(v, null, answers);
    try f.setLatest(o, try f.rootVal(v));
}

/// The tracked roots and entries whose handles atom `a` can be (kernel §13):
/// a tracked parameter's or capture's handle (item 11), a new cell's handle
/// that a tracked root holds (`Root.cell_root`), and through the runs of the
/// frame's roots at a handle's location. An answer's and a handle outside
/// the frame are no root the frame follows.
fn cellOrigins(f: *Frame, a: Atom, out: *std.ArrayList([3]u32)) Error!void {
    const m = f.m;
    var stack: std.ArrayList(Atom) = .empty;
    defer stack.deinit(f.gpa);
    try stack.append(f.gpa, a);
    while (stack.pop()) |x| {
        if (f.charge(1)) return;
        const r = f.roots.items[x.root];
        switch (r.kind) {
            .param, .capture => if (r.tracked and m.loc.layoutEntries(r.layout)[x.e].kind == .cell) try out.append(f.gpa, .{ x.root, x.e, none }),
            .fresh => if (r.cell_root != none) try out.append(f.gpa, .{ r.cell_root, r.cell_e, none }),
            .local => {
                if (m.loc.layoutEntries(r.layout)[x.e].kind != .cell) continue;
                const ent = f.rents.items[r.ent + x.e];
                _ = f.charge(ent.len);
                try stack.appendSlice(f.gpa, f.atoms.items[ent.start..][0..ent.len]);
            },
            .outside, .answer => {},
        }
    }
}

/// Each handle of a root the frame follows that the atoms
/// `f.atoms[start..end]` can be has another holder (kernel §13). It is
/// noted, and made at the next `flushShare`: a share makes a version, whose
/// runs go to `f.atoms`, and the caller can be making a run there.
fn shareAtoms(f: *Frame, start: usize, end: usize, point: u32) Error!void {
    if (!f.cells_any) return;
    for (start..end) |i| {
        const before = f.share_pending.items.len;
        try f.cellOrigins(f.atoms.items[i], &f.share_pending);
        for (f.share_pending.items[before..]) |*o| o[2] = point;
    }
}

/// The shares `shareAtoms` noted, made: a share escapes contents, which
/// can note more.
fn flushShare(f: *Frame) Error!void {
    while (f.share_pending.pop()) |o| try f.shareCell(o[0], o[1], o[2]);
}

/// Each handle that value `v` can hold has another holder (noted).
fn shareVal(f: *Frame, v: Val, point: u32) Error!void {
    if (!f.cells_any or v == v_none or v == v_outside) return;
    const start = f.atoms.items.len;
    _ = try f.allLeaves(v, &f.atoms);
    try f.shareAtoms(start, f.atoms.items.len, point);
    f.atoms.shrinkRetainingCapacity(start);
}

/// Each handle that a handle's location of root `root` holds, other than
/// the root's own (a version's, or a new cell's that `cellResult` named), has
/// another holder: the root copied it (a list, a record, a call's answer, a
/// cell's renewed contents).
fn shareCopies(f: *Frame, root: u32, only: ?[]const u32, point: u32) Error!void {
    if (!f.cells_any) return;
    const r = f.roots.items[root];
    const es = f.m.loc.layoutEntries(r.layout);
    for (es, 0..) |e, k| {
        if (e.kind != .cell) continue;
        if (only) |ks| if (std.mem.indexOfScalar(u32, ks, @intCast(k)) == null) continue;
        const ent = f.rents.items[r.ent + k];
        try f.shareAtoms(ent.start, ent.start + ent.len, point);
    }
}

/// The handle at entry `e` of tracked root `o` has another holder (kernel
/// §13): what its contents hold now escapes, since the other holder can read
/// them at any later time, and from now on they hold `outside` too, since it
/// can store into them where the frame does not see.
fn shareCell(f: *Frame, o: u32, e: u32, point: u32) Error!void {
    const got = try f.cell_shared.getOrPut(f.gpa, .{ o, e });
    if (got.found_existing) return;
    const r = f.roots.items[o];
    const cur = f.latestOf(o) orelse try f.rootVal(o);
    var ks: std.ArrayList(u32) = .empty;
    defer ks.deinit(f.gpa);
    try f.contentsAt(r.layout, e, &ks);
    // Contents of a type of no location (`Fiber ⊤`) hold no cell: nothing
    // to escape, and no version to make.
    if (ks.items.len == 0) return;
    const start: u32 = @intCast(f.atoms.items.len);
    for (ks.items) |k| _ = try f.leavesAs(cur, r.place, k, &f.atoms);
    try f.noteEscape(start, point);
    const v = try f.versionOf(o, cur, point);
    const ent0 = f.roots.items[v].ent;
    for (ks.items) |k| {
        const old = f.rents.items[ent0 + k];
        const at: u32 = @intCast(f.atoms.items.len);
        const olds = try f.gpa.dupe(Atom, f.atoms.items[old.start..][0..old.len]);
        try f.atoms.appendSlice(f.gpa, olds);
        try f.atoms.append(f.gpa, outside_atom);
        f.rents.items[ent0 + k] = .{ .kind = .alias, .start = at, .len = @intCast(f.atoms.items.len - at), .twice = old.twice };
    }
    try f.finishVersion(o, v);
}

/// The answer of a call, root `root`: where each handle's location holds one
/// handle the callee made in this call, which no other location holds and
/// which it did not let escape, the frame follows the root's contents
/// (kernel §13). Else every handle it holds has another holder, and its
/// contents hold `outside` too (`rootLeaves`).
fn cellResult(f: *Frame, root: u32, roots_before: usize, point: u32) Error!void {
    const r = f.roots.items[root];
    if (!r.cells) return;
    const es = f.m.loc.layoutEntries(r.layout);
    var ok = true;
    for (es, 0..) |e, k| {
        if (e.kind != .cell) continue;
        const ent = f.rents.items[r.ent + k];
        if (ent.hasOwn() or ent.twice or ent.len != 1) {
            ok = false;
            break;
        }
        const a = f.atoms.items[ent.start];
        const ar = f.roots.items[a.root];
        if (ar.kind != .fresh or a.root < roots_before or ar.escaped or ar.cell_root != none) {
            ok = false;
            break;
        }
        // One handle at two locations of the answer.
        for (es[0..k], 0..) |e2, k2| if (e2.kind == .cell) {
            const ent2 = f.rents.items[r.ent + k2];
            if (ent2.len == 1 and f.atoms.items[ent2.start].root == a.root) ok = false;
        };
        if (!ok) break;
    }
    if (!ok) {
        try f.shareCopies(root, null, point);
        return f.flushShare();
    }
    f.roots.items[root].tracked = true;
    f.cells_any = true;
    for (es, 0..) |e, k| if (e.kind == .cell) {
        const h = f.atoms.items[f.rents.items[r.ent + k].start].root;
        f.roots.items[h].cell_root = root;
        f.roots.items[h].cell_e = @intCast(k);
    };
}

/// The renewals of a call (kernel §13, `Contract.renew`): for each handle of
/// a parameter whose contents the callee renews, the argument's root gets a
/// new version where the frame follows it, and otherwise what the callee
/// stores escapes and the handle has another holder.
fn renewCells(f: *Frame, base: *const Use, c: *const Contract, args: []const Val, casts: bool, inst: u32) Error!void {
    const m = f.m;
    try f.flushShare();
    for (0..c.arity) |j| {
        const sig = c.layouts[j];
        const ses = m.loc.layoutEntries(sig);
        var done: ?[]bool = null;
        for (ses, 0..) |he, h| {
            if (he.kind != .cell) continue;
            if (done) |d| if (d[h]) continue;
            var ks: std.ArrayList(u32) = .empty;
            defer ks.deinit(f.gpa);
            try f.contentsAt(sig, @intCast(h), &ks);
            const renewed = for (ks.items) |k| {
                if (c.renewAt(c.off[j] + k) != null) break true;
            } else false;
            if (!renewed) continue;
            if (done == null) {
                done = try f.gpa.alloc(bool, ses.len);
                @memset(done.?, false);
            }
            for (ks.items) |k| done.?[k] = true;
            try f.renewHandle(base, c, @intCast(j), @intCast(h), ks.items, args[j], casts, false, inst);
        }
    }
}

/// `maybe`: the call may leave the contents as they were (a function a
/// callee runs any number of times, kernel §13 item 11): a location whose
/// renewal does not name its own old contents keeps them too.
fn renewHandle(f: *Frame, base: *const Use, c: *const Contract, j: u32, h: u32, ks: []const u32, v: Val, casts: bool, maybe: bool, inst: u32) Error!void {
    const m = f.m;
    const sig = c.layouts[j];
    // A hole of markup can be evaluated where the markup is rendered, after
    // what the walk sees next (kernel §6.12): no version is made there.
    const tgt = if (f.markup_reads == null) try f.renewTarget(v, sig, h) else null;
    if (tgt) |t| if (!f.cell_shared.contains(.{ t.o, t.hx })) {
        const r = f.roots.items[t.o];
        const xl = r.layout;
        const xes = m.loc.layoutEntries(xl);
        const cov = try m.loc.cover(sig, xl);
        var xks: std.ArrayList(u32) = .empty;
        defer xks.deinit(f.gpa);
        try f.contentsAt(xl, t.hx, &xks);
        // A summary location holds the contents of many cells, of which the
        // call renews one: the others keep what they held.
        const strong = xes[t.hx].single;
        const ver = try f.versionOf(t.o, v, inst);
        const ent0 = f.roots.items[ver].ent;
        for (xks.items) |k| {
            const start: u32 = @intCast(f.atoms.items.len);
            var st: SrcState = .{ .inst = inst, .typed = !casts };
            const cr = cov[k];
            if (cr == none) {
                try f.atoms.append(f.gpa, outside_atom);
            } else if (cr == Loc.all) {
                for (ks) |sk| if (c.renewAt(c.off[j] + sk)) |srcs| try f.expandSrcs(base, srcs, sig, sk, xl, k, &st);
            } else if (c.renewAt(c.off[j] + cr)) |srcs| {
                try f.expandSrcs(base, srcs, sig, cr, xl, k, &st);
            } else {
                // A location of the contents that the callee leaves as it was.
                _ = try f.leavesAs(v, r.place, k, &f.atoms);
            }
            if (!strong or (maybe and !selfRenew(c, j, cr))) _ = try f.leavesAs(v, r.place, k, &f.atoms);
            try f.uniqueTail(&f.atoms, start);
            f.rents.items[ent0 + k] = .{ .kind = if (st.written) .version else .alias, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = !xes[k].single and (st.twice or !strong or f.curTwice(v, k)) };
        }
        // A captured cell is held by the code's holder too, which reads it at
        // any later time (kernel §13 item 11): what the call stores there
        // that the holder cannot name escapes in this frame — a value the
        // code was handed (a callee that runs it can hand it back), or one
        // read through such a value. The cell's own old contents, another
        // capture and a cell the code made are named to the holder by the
        // renewal, and read where the code answers (item 7); a cell it made
        // that it answers too is no answer of its own (`freshOwn`).
        if (f.roots.items[t.o].kind == .capture) {
            var kept: std.ArrayList(Atom) = .empty;
            defer kept.deinit(f.gpa);
            for (xks.items) |k| {
                const ent = f.rents.items[ent0 + k];
                for (f.atoms.items[ent.start..][0..ent.len]) |a| {
                    if (f.originOf(a.root) == t.o) continue;
                    const ar = f.roots.items[a.root];
                    const named = switch (ar.kind) {
                        .capture, .fresh => true,
                        .local => f.rents.items[ar.ent + a.e].kind == .own,
                        .outside, .param, .answer => false,
                    };
                    if (!named) try kept.append(f.gpa, a);
                }
            }
            const es: u32 = @intCast(f.atoms.items.len);
            try f.atoms.appendSlice(f.gpa, kept.items);
            try f.noteEscape(es, inst);
            f.atoms.shrinkRetainingCapacity(es);
        }
        // A handle the call stored in the contents is held there as well as
        // where it was (`shareCopies`).
        try f.shareCopies(ver, xks.items, inst);
        try f.finishVersion(t.o, ver);
        return f.flushShare();
    };
    // Not followed (kernel §13): what the call stores in the cell escapes,
    // and each handle of a root the frame follows that the argument holds
    // there has another holder.
    const start: u32 = @intCast(f.atoms.items.len);
    for (ks) |sk| if (c.renewAt(c.off[j] + sk)) |srcs| {
        // Every part of what it stores: the signature reads it as one place.
        var st: SrcState = .{ .inst = inst, .typed = !casts, .whole = true };
        try f.expandSrcs(base, srcs, sig, sk, sig, sk, &st);
    };
    try f.noteEscape(start, inst);
    const hs = f.atoms.items.len;
    _ = try f.argLeaves(v, sig, h, &.{}, false, &f.atoms);
    try f.shareAtoms(hs, f.atoms.items.len, inst);
    try f.flushShare();
}

/// Whether the renewal of parameter `j` at its entry `cr` names that
/// entry's own old contents: then a call that leaves the contents as they
/// were leaves cells the renewal names.
fn selfRenew(c: *const Contract, j: u32, cr: u32) bool {
    if (cr >= Loc.all) return false;
    const srcs = c.renewAt(c.off[j] + cr) orelse return true;
    for (srcs) |s| if (s.kind == .param and s.a == j and s.e == cr) return true;
    return false;
}

const CellTarget = struct { o: u32, hx: u32 };

/// The tracked root whose handle an argument `v` is at the signature's
/// handle entry `h`, with that handle's entry: `v` is the root whole (or one
/// of its versions, or a join of them), and the call map puts exactly one
/// entry of the root's layout, a handle, at `h`. Else null.
fn renewTarget(f: *Frame, v: Val, sig: u32, h: u32) Error!?CellTarget {
    const m = f.m;
    var o: u32 = none;
    if (!f.wholeTracked(v, &o, 0)) return null;
    const r = f.roots.items[o];
    const cov = try m.loc.cover(sig, r.layout);
    const xes = m.loc.layoutEntries(r.layout);
    var hx: u32 = none;
    _ = f.charge(cov.len);
    for (cov, 0..) |cr, k| {
        if (cr == h) {
            if (hx != none) return null;
            hx = @intCast(k);
        } else if (cr == Loc.all and xes[k].kind == .cell) return null;
    }
    if (hx == none or xes[hx].kind != .cell) return null;
    return .{ .o = o, .hx = hx };
}

fn wholeTracked(f: *const Frame, v: Val, o: *u32, depth: u32) bool {
    if (depth > 8) return false;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .ref => {
            const r = f.roots.items[n.a];
            if (!r.tracked or n.b != r.path) return false;
            const x = f.originOf(n.a);
            if (o.* == none) o.* = x else if (o.* != x) return false;
            return true;
        },
        .join => {
            for (0..n.b) |ki| if (!f.wholeTracked(f.lists.items[n.a + 2 * ki], o, depth + 1)) return false;
            return true;
        },
        .none, .outside, .fnref, .closure, .unknown, .built, .later => return false,
    }
}

/// Before a call that reads, writes or renews the contents of cells: a
/// handle that the arguments hold at two such locations (two parameters, or
/// two locations of one) is two names of one cell to the callee, whose walk
/// read them as apart (kernel §4.4, the apart-arguments rule): it has
/// another holder.
fn cellsApart(f: *Frame, c: *const Contract, args: []const Val, inst: u32) Error!void {
    if (!f.cells_any) return;
    const m = f.m;
    var seen: std.ArrayList([2]u32) = .empty;
    defer seen.deinit(f.gpa);
    var twice: std.ArrayList([2]u32) = .empty;
    defer twice.deinit(f.gpa);
    for (0..c.arity) |j| {
        const sig = c.layouts[j];
        const inner = try f.innerOf(sig);
        if (inner.len == 0) continue;
        for (m.loc.layoutEntries(sig), 0..) |he, h| {
            if (he.kind != .cell) continue;
            var ks: std.ArrayList(u32) = .empty;
            defer ks.deinit(f.gpa);
            try f.contentsAt(sig, @intCast(h), &ks);
            var touched = c.flags[c.off[j] + h] != 0;
            for (ks.items) |k| {
                if (c.flags[c.off[j] + k] != 0 or c.renewAt(c.off[j] + k) != null) touched = true;
            }
            if (!touched) continue;
            const start = f.atoms.items.len;
            const dup = try f.argLeaves(args[j], sig, @intCast(h), &.{}, false, &f.atoms);
            var os: std.ArrayList([3]u32) = .empty;
            defer os.deinit(f.gpa);
            for (f.atoms.items[start..]) |a| try f.cellOrigins(a, &os);
            f.atoms.shrinkRetainingCapacity(start);
            // One location of one argument names each handle once, though its
            // values (the arms of a join) can each name it.
            const here = seen.items.len;
            for (os.items) |o| {
                const again = for (seen.items, 0..) |x, i| {
                    if (x[0] == o[0] and x[1] == o[1]) break i;
                } else null;
                if (again) |i| {
                    if (i < here) try twice.append(f.gpa, .{ o[0], o[1] });
                    continue;
                }
                if (dup and !he.single) try twice.append(f.gpa, .{ o[0], o[1] });
                try seen.append(f.gpa, .{ o[0], o[1] });
            }
        }
    }
    for (twice.items) |o| try f.shareCell(o[0], o[1], inst);
    try f.flushShare();
}

/// A known function that renews the contents of a cell it is handed (kernel
/// §13) runs where its holder runs it, at times the frame does not see: each
/// handle it is handed there has another holder, and what it stores escapes.
/// `own_only`: the captures' renewals were made where the code runs (`captureCells`).
fn flowRenews(f: *Frame, code: Code, use: *const Use, own_only: bool) Error!void {
    const m = f.m;
    const lc = code.contract;
    if (!lc.renews()) return;
    const inst = use.site.inst;
    for (0..lc.arity) |k| {
        if (own_only and k >= code.own_params) break;
        const sig = lc.layouts[k];
        for (m.loc.layoutEntries(sig), 0..) |he, h| {
            if (he.kind != .cell) continue;
            var ks: std.ArrayList(u32) = .empty;
            defer ks.deinit(f.gpa);
            try f.contentsAt(sig, @intCast(h), &ks);
            var renewed = false;
            // A writer's renewal of its cell's own contents keeps them in the
            // cell the frame follows (kernel §13 item 12).
            const writer = k >= code.own_params and f.isWriter(code, k - code.own_params);
            for (ks.items) |le| if (lc.renewAt(lc.off[k] + le)) |srcs| {
                renewed = true;
                for (srcs) |s| {
                    if (writer and s.kind == .param and s.a == k) continue;
                    try f.flowStored(code, use, s, inst);
                }
            };
            if (!renewed) continue;
            // The handle: what the holder hands there, or the captured value.
            if (k >= code.own_params) {
                // A writer runs at the frame's switch points (kernel §13 item 12).
                if (f.isWriter(code, k - code.own_params)) continue;
                const start = f.atoms.items.len;
                _ = try f.argLeaves(try f.capVal(code, k - code.own_params), sig, @intCast(h), &.{}, false, &f.atoms);
                try f.shareAtoms(start, f.atoms.items.len, inst);
            } else if (use.kind != .top) {
                var slots: std.ArrayList(Slot) = .empty;
                defer slots.deinit(f.gpa);
                var sink: ShareSink = .{ .inst = inst };
                if (try f.slotsOf(use, @intCast(k), sig, @intCast(h), null, &slots)) {
                    for (slots.items) |slot| for (slot.srcs) |ss| try f.resolve(use, ss, &.{}, false, &sink, 0);
                } else try sink.lost(f, use);
            }
        }
    }
}

/// A source `s` of what the known function `code` stores in a cell, at
/// `use`: it escapes.
fn flowStored(f: *Frame, code: Code, use: *const Use, s: Src, inst: u32) Error!void {
    const lc = code.contract;
    switch (s.kind) {
        .outside, .twice => {},
        // A cell the function made: no holder of the frame has it.
        .fresh => {},
        .param => {
            if (s.a >= code.own_params) {
                const capv = try f.capVal(code, s.a - code.own_params);
                const start: u32 = @intCast(f.atoms.items.len);
                _ = try f.argLeaves(capv, lc.layouts[s.a], s.e, &.{}, false, &f.atoms);
                try f.noteEscape(start, inst);
            } else if (use.kind != .top) {
                var slots: std.ArrayList(Slot) = .empty;
                defer slots.deinit(f.gpa);
                var sink: EscSink = .{ .inst = inst };
                if (try f.slotsOf(use, s.a, lc.layouts[s.a], s.e, null, &slots)) {
                    for (slots.items) |slot| for (slot.srcs) |ss| try f.resolve(use, ss, &.{}, false, &sink, 0);
                } else try sink.lost(f, use);
            }
        },
        // The answer of a function the function was handed: what the holder
        // handed it can be there.
        .answer => {
            var u: ?*const Use = use;
            while (u) |x| : (u = f.upOf(x)) for (x.args) |v| try f.escape(v, inst);
            for (0..code.ncaps) |kc| try f.escape(try f.capVal(code, kc), inst);
        },
    }
}

/// The parts of a source are handles with another holder (`flowRenews`).
const ShareSink = struct {
    inst: u32,

    fn outside(_: *ShareSink, _: *Frame) Error!void {}
    fn held(_: *ShareSink, _: *Frame) Error!void {}
    fn lost(s: *ShareSink, f: *Frame, use: *const Use) Error!void {
        var u: ?*const Use = use;
        while (u) |x| : (u = f.upOf(x)) for (x.args) |v| try f.shareVal(v, s.inst);
    }
    fn atoms(s: *ShareSink, f: *Frame, h: Handed) Error!void {
        try f.shareAtoms(h.start, f.atoms.items.len, s.inst);
    }
    fn answer(s: *ShareSink, f: *Frame, level: *const Use, src: Src, suffix: []const u64, _: bool) Error!void {
        const start: u32 = @intCast(f.atoms.items.len);
        var st: SrcState = .{ .inst = s.inst, .whole = true };
        try f.answerOfParam(level, src, suffix, &st, 0);
        try f.shareAtoms(start, f.atoms.items.len, s.inst);
    }
};

/// The renewals a frame publishes (kernel §13): for each tracked parameter
/// that a call renewed, at each location of its cells' contents, the
/// sources of its latest version, joined with its value at each early
/// return. Empty where no parameter was renewed.
fn publishRenew(f: *Frame, flags: []u8, off: []const u32, total: u32) Error![]const ?[]const Src {
    const m = f.m;
    try f.flushShare();
    if (f.cell_roots.items.len == 0) return &.{};
    const rn = try m.arena.alloc(?[]const Src, total);
    @memset(rn, null);
    var any = false;
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    var tmp: std.ArrayList(Atom) = .empty;
    defer tmp.deinit(f.gpa);
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    for (f.params.items, 0..) |root, j| {
        const r = f.roots.items[root];
        if (!r.tracked or !f.renewedAt(root)) continue;
        vals.clearRetainingCapacity();
        for (f.ret_cells.items) |rc| if (rc[0] == root) try vals.append(f.gpa, rc[1]);
        const val = if (vals.items.len == 1) vals.items[0] else try f.joinVal(r.place, vals.items, &.{});
        const inner = try f.innerOf(r.layout);
        const es = m.loc.layoutEntries(r.layout);
        for (inner, 0..) |in, k| if (in) {
            tmp.clearRetainingCapacity();
            const dup = try f.leavesAs(val, r.place, @intCast(k), &tmp);
            try f.uniqueTail(&tmp, 0);
            srcs.clearRetainingCapacity();
            f.newVisit();
            for (tmp.items) |a| try f.atomSrcsIn(a, &srcs);
            if (dup and !es[k].single) try srcs.append(f.gpa, Src.twice);
            const out = try CMod.normal(m.arena, srcs.items);
            rn[off[j] + k] = out;
            // What the call leaves in the cell is answered there: another
            // operand of a call that writes, and read (kernel §5, test 2).
            for (out) |s| if (s.kind == .param) {
                flags[off[s.a] + s.e] |= flag_a | flag_r;
            };
            any = true;
        };
    }
    return if (any) rn else &.{};
}

/// At a return point (a `?`, the end of the walk): each tracked
/// parameter's value there, for `publishRenew`, and the read of its cells'
/// contents there, at this time and in this context (`cellReads`).
fn noteReturnCells(f: *Frame, point: u32) Error!void {
    if (!f.cells_any) return;
    try f.flushShare();
    for (f.params.items) |root| if (f.roots.items[root].tracked) {
        const v = f.latestOf(root) orelse try f.rootVal(root);
        try f.ret_cells.append(f.gpa, .{ root, v });
        // The contents of its cells, not the rest of it: the caller reads
        // the rest where it reads it.
        const inner = try f.innerOf(f.roots.items[root].layout);
        const start: u32 = @intCast(f.lists.items.len);
        for (inner, 0..) |in, k| if (in) try f.lists.append(f.gpa, @intCast(k));
        const nmask: u32 = @intCast(f.lists.items.len - start);
        try f.ret_reads.append(f.gpa, .{ .point = point, .at = f.timeOf(point), .val = v, .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = false, .tail = true });
    };
}

/// Whether a call renewed tracked parameter `root`'s cells on a way to
/// some return point: its value there is a version, not the root itself.
fn renewedAt(f: *const Frame, root: u32) bool {
    for (f.ret_cells.items) |rc| if (rc[0] == root) {
        // A rename at a switch point is no renewal (kernel §13 item 12).
        if (!f.onlyRenamed(rc[1], root, 0)) return true;
    };
    return false;
}

/// Where the frame answers, what its calls left in a renewed parameter's
/// cells is read, by the caller after the call, as its answer is (kernel
/// §13), at every return point: one where a call renewed them, and one
/// where the cells still hold their old contents, which the caller reads as
/// the renewal's old names (a body that wrote them in place before an
/// early return is refused there).
fn cellReads(f: *Frame) Error!void {
    for (f.params.items) |root| if (f.roots.items[root].tracked and f.renewedAt(root)) {
        for (f.ret_cells.items, f.ret_reads.items) |rc, rd| if (rc[0] == root and rd.nmask != 0) try f.uses.append(f.gpa, rd);
    };
}

/// The latest versions of the tracked roots, to be joined after a part of
/// the walk that may not run (`joinCells`).
fn saveCells(f: *Frame) Error!?[]const [2]u32 {
    if (!f.cells_any) return null;
    try f.flushShare();
    var out: std.ArrayList([2]u32) = .empty;
    for (f.cell_roots.items) |o| if (f.roots.items[o].latest != none) try out.append(f.gpa, .{ o, f.roots.items[o].latest });
    return out.items;
}

/// The latest versions `saveCells` saved, again.
fn restoreCells(f: *Frame, saved: []const [2]u32) Error!void {
    for (f.cell_roots.items) |o| f.roots.items[o].latest = none;
    f.cell_roots.clearRetainingCapacity();
    for (saved) |x| {
        f.roots.items[x[0]].latest = x[1];
        try f.cell_roots.append(f.gpa, x[0]);
    }
}

/// The value of tracked root `o`'s latest version, or null when a call renewed none.
fn latestOf(f: *const Frame, o: u32) ?Val {
    const l = f.roots.items[o].latest;
    return if (l == none) null else l;
}

fn setLatest(f: *Frame, o: u32, v: Val) Error!void {
    if (f.roots.items[o].latest == none) try f.cell_roots.append(f.gpa, o);
    f.roots.items[o].latest = v;
}

fn savedOf(saved: []const [2]u32, o: u32) ?Val {
    for (saved) |x| if (x[0] == o) return x[1];
    return null;
}

/// After the arms of a `case` (`ctxs` each arm's context, `arms` the latest
/// versions each arm left), or after a part of the walk that may not run (one
/// arm, the state before, with no context): a root whose latest differs
/// between them is read as the join of them, each in its arm (kernel §13).
fn joinCells(f: *Frame, arms: []const []const [2]u32, ctxs: []const u32) Error!void {
    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(f.gpa);
    for (arms) |a| for (a) |x| if (std.mem.indexOfScalar(u32, keys.items, x[0]) == null) try keys.append(f.gpa, x[0]);
    _ = f.charge(keys.items.len * arms.len);
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    try f.restoreCells(&.{});
    for (keys.items) |o| {
        vals.clearRetainingCapacity();
        for (arms) |a| try vals.append(f.gpa, savedOf(a, o) orelse try f.rootVal(o));
        const same = for (vals.items[1..]) |x| {
            if (x != vals.items[0]) break false;
        } else true;
        const v = if (same) vals.items[0] else try f.joinVal(f.roots.items[o].place, vals.items, ctxs);
        try f.setLatest(o, v);
    }
}

// ---- switch points (kernel §13 item 12) -------------------------------------------------

/// Whether another fiber can run inside the call at `inst`: its callee may
/// be impure or may suspend (`Dispatch.effectAt`). An impure call that does
/// not suspend can run other fibers too: `Task.fromHost` drains the fiber
/// queue when its callback returns. A module with no effect table: every
/// call can.
fn switchAt(f: *const Frame, inst: u32) bool {
    const dt = f.m.in.dispatch orelse return true;
    const s = dt.effectAt(@fromBackingInt(inst));
    return s.impure or s.own != .no;
}

/// At a call where another fiber can run, after its arguments are
/// evaluated and before the call reads them (`ops`): each function that
/// writes a cell the frame made and runs in another fiber runs
/// (`runWriter`), and the contents of each tracked parameter's and
/// capture's cells are probed and renamed (`probeCells`).
fn switchPoint(f: *Frame, inst: u32, ops: []const Val, c: ?*const Contract) Error!void {
    if (!f.switchAt(inst)) return;
    f.switched = true;
    if (!f.cells_any) return;
    try f.flushShare();
    // A call in a hole of markup can run where the markup renders, after
    // what the walk sees next (kernel §6.12): every holder of a cell there
    // is marked, and no writer of the frame's cells runs in another fiber.
    if (f.markup_reads != null) {
        for (f.params.items) |root| if (f.roots.items[root].tracked) {
            const r = f.roots.items[root];
            for (f.m.loc.layoutEntries(r.layout), 0..) |he, h| if (he.kind == .cell) {
                f.pflags.items[r.ent + h] |= CMod.flag_m;
            };
        };
        for (f.writers.items) |w| try f.cell_marked.put(f.gpa, .{ w.o, w.e }, {});
        return;
    }
    const followed = try f.followedOps(ops.len, c);
    defer f.gpa.free(followed);
    for (0..f.writers.items.len) |i| try f.runWriter(f.writers.items[i], inst, ops, followed);
    try f.probeCells(inst, ops, followed);
}

/// Per operand of a call whose contract is `c` (or none: unknown code):
/// whether a handle there is one the callee follows, a parameter whose
/// layout has a cell, so its walk probes the contents and publishes the
/// mark (item 12). A handle at a type variable, or handed to code the walk
/// does not know, is no handle read through itself.
fn followedOps(f: *Frame, n: usize, c: ?*const Contract) Error![]bool {
    const out = try f.gpa.alloc(bool, n);
    for (out, 0..) |*x, i| {
        x.* = false;
        const cc = c orelse continue;
        if (i >= cc.arity) continue;
        x.* = (try f.innerOf(cc.layouts[i])).len != 0;
    }
    return out;
}

/// Whether the operand `o` of a switch point reaches the contents `ws` of
/// the cell of tracked root `root`: a handle read through itself, and a
/// closure's capture of it, read the contents where they read them.
fn opReaches(f: *Frame, o: Val, ws: []const Atom, root: u32, follow: bool) Error!bool {
    if (o == v_none or o == v_outside or (follow and f.isHandleOf(o, root))) return false;
    if (f.nodes.items[o].tag == .closure) {
        const code = f.codes.items[f.nodes.items[o].a];
        for (0..code.ncaps) |k| {
            const cv = try f.capVal(code, k);
            if (keepsCapture(code, k)) {
                if (try f.otherReaches(.{ .v = cv }, ws, none, &.{})) return true;
                continue;
            }
            if (try f.opReaches(cv, ws, root, true)) return true;
        }
        return false;
    }
    return f.otherReaches(.{ .v = o }, ws, none, &.{});
}

/// Whether the known function `code` hands something of its capture `k` to
/// the code that runs it: its answer or a renewal names the capture, or it
/// lets it escape. Then a handle it captured is no handle read through
/// itself: the callee can hold what it answers (a value taken out of the
/// cell, or the handle) across its own switch points (kernel §13 item 12).
fn keepsCapture(code: Code, k: usize) bool {
    const lc = code.contract;
    const j = code.own_params + k;
    if (j >= lc.arity) return true;
    for (lc.flags[lc.off[j]..lc.off[j + 1]]) |x| if (x & flag_e != 0) return true;
    for (lc.res) |srcs| for (srcs) |s| if (s.kind == .param and s.a == j) return true;
    for (0..lc.arity) |a| if (a != j) for (lc.off[a]..lc.off[a + 1]) |i| if (lc.renewAt(i)) |srcs| for (srcs) |s| if (s.kind == .param and s.a == j) return true;
    return false;
}

/// Whether value `v` is tracked root `o` whole, or a version of it: a handle
/// read through itself reads the contents as they are when it reads them.
fn isHandleOf(f: *const Frame, v: Val, o: u32) bool {
    if (v == v_none or v == v_outside) return false;
    var x: u32 = none;
    return f.wholeTracked(v, &x, 0) and x == o;
}

/// Kernel §13 item 12, the probe: at the switch point `inst`, the contents of
/// each handle of each tracked parameter and capture as they are now. A
/// value taken out of them before is held across the switch where it is
/// read after it, where it escaped before it, or where the call reads it
/// (`ops`, but a handle read through itself): judged at the end of the walk
/// (`finishProbes`), a refusal is the mark (`Contract.flag_m`) on the handle,
/// no diagnostic. Then the contents get a new name for probes
/// (`renameContents`): a value taken out of the cell after the call is no
/// value taken before it.
fn probeCells(f: *Frame, inst: u32, ops: []const Val, followed: []const bool) Error!void {
    const at = f.timeOf(inst);
    for (f.params.items) |root| {
        const r = f.roots.items[root];
        if (!r.tracked) continue;
        const es = f.m.loc.layoutEntries(r.layout);
        const cur = f.latestOf(root) orelse try f.rootVal(root);
        var probed = false;
        for (es, 0..) |he, h| {
            if (he.kind != .cell) continue;
            // A shared handle's contents escaped already: the contract says so.
            if (f.cell_shared.contains(.{ root, @intCast(h) })) continue;
            var ks: std.ArrayList(u32) = .empty;
            defer ks.deinit(f.gpa);
            try f.contentsAt(r.layout, @intCast(h), &ks);
            if (ks.items.len == 0) continue;
            const w: u32 = @intCast(f.atoms.items.len);
            for (ks.items) |k| _ = try f.leavesAs(cur, r.place, k, &f.atoms);
            try f.uniqueTail(&f.atoms, w);
            const wn: u32 = @intCast(f.atoms.items.len - w);
            probed = true;
            var refused = false;
            const ws = f.atoms.items[w..][0..wn];
            f.judge_ctx = f.cur_ctx;
            f.judge_at = at;
            f.judge_probe = true;
            for (ops, 0..) |o, oi| if (try f.opReaches(o, ws, root, oi < followed.len and followed[oi])) {
                refused = true;
                break;
            };
            if (!refused) for (f.escapes.items) |e| {
                if (!f.compatible(e.ctx, f.cur_ctx)) continue;
                if (f.overlapWrite(f.esc_atoms.items[e.start..][0..e.len], ws)) {
                    refused = true;
                    break;
                }
            };
            f.judge_ctx = none;
            f.judge_at = none;
            f.judge_probe = false;
            try f.probes.append(f.gpa, .{ .w = w, .wn = wn, .at = at, .ctx = f.cur_ctx, .root = root, .h = @intCast(h), .refused = refused });
        }
        if (probed) try f.renameContents(root, cur, inst, at);
    }
}

/// A version of tracked root `root` whose value now is `cur`, the same
/// cells, each copy in a cell's contents taken at time `at` (`Atom.ren`):
/// no rename is a write (`dead` stays), and no renewal (`renewedAt`).
fn renameContents(f: *Frame, root: u32, cur: Val, inst: u32, at: u32) Error!void {
    const v = try f.versionOf(root, cur, inst);
    f.roots.items[v].rename_of = cur;
    const inner = try f.innerOf(f.roots.items[root].layout);
    const ent0 = f.roots.items[v].ent;
    for (inner, 0..) |in, k| if (in) {
        const ent = f.rents.items[ent0 + k];
        for (f.atoms.items[ent.start..][0..ent.len]) |*a| a.ren = at;
    };
    try f.finishVersion(root, v);
}

/// Whether `v`, the value of tracked root `root` at a return point, is the
/// root itself through renames only (`renameContents`): no call renewed it.
fn onlyRenamed(f: *const Frame, v: Val, root: u32, depth: u32) bool {
    if (depth > 64) return false;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .ref => {
            if (n.a == root) return true;
            const p = f.roots.items[n.a].rename_of;
            return p != none and f.onlyRenamed(p, root, depth + 1);
        },
        .join => {
            for (0..n.b) |ki| if (!f.onlyRenamed(f.lists.items[n.a + 2 * ki], root, depth + 1)) return false;
            return true;
        },
        .none, .outside, .fnref, .closure, .unknown, .built, .later => return false,
    }
}

/// The probes judged against the reads after each (kernel §13 item 12):
/// a refused one marks its handle in the contract.
fn finishProbes(f: *Frame) Error!void {
    for (f.probes.items) |p| {
        var refused = p.refused or f.failed or f.m.steps_over;
        if (!refused) {
            const ws = f.atoms.items[p.w..][0..p.wn];
            f.judge_ctx = p.ctx;
            f.judge_at = p.at;
            f.judge_probe = true;
            defer {
                f.judge_ctx = none;
                f.judge_at = none;
                f.judge_probe = false;
            }
            if (f.charge(f.uses.items.len)) refused = true;
            if (!refused) for (f.uses.items) |u| {
                if (u.at <= p.at) continue;
                if (!f.compatible(u.ctx, p.ctx)) continue;
                if (f.tick()) {
                    refused = true;
                    break;
                }
                if (try f.useReaches(u, ws)) {
                    refused = true;
                    break;
                }
            };
        }
        if (refused) {
            const r = f.roots.items[p.root];
            f.pflags.items[r.ent + p.h] |= CMod.flag_m;
        }
    }
}

/// The holders of the handles that `v` holds at entry `h` of `sig` are
/// marked (`Contract.flag_m`): a parameter's or a capture's in the
/// contract, a root the frame made in `cell_marked`.
fn markHandles(f: *Frame, v: Val, sig: u32, h: u32) Error!void {
    if (v == v_none or v == v_outside) return;
    const start = f.atoms.items.len;
    defer f.atoms.shrinkRetainingCapacity(start);
    _ = try f.argLeaves(v, sig, h, &.{}, false, &f.atoms);
    const hs = try f.gpa.dupe(Atom, f.atoms.items[start..]);
    defer f.gpa.free(hs);
    try f.markAtoms(hs, CMod.flag_m);
    var os: std.ArrayList([3]u32) = .empty;
    defer os.deinit(f.gpa);
    for (hs) |a| try f.cellOrigins(a, &os);
    for (os.items) |o| try f.cell_marked.put(f.gpa, .{ o[0], o[1] }, {});
}

/// The marks of a contract `c` applied to the values `args` at a call or a
/// use (kernel §13 item 12): each handle it marks, and each handle whose
/// contents it hands a function that can run other fibers while it holds
/// them (`fnSwitches`): a function the frame was handed is judged by the
/// frame's caller, through the supply the frame publishes.
fn applyMarks(f: *Frame, c: *const Contract, args: []const Val) Error!void {
    if (!f.cells_any) return;
    const m = f.m;
    for (0..@min(c.arity, args.len)) |j| {
        const sig = c.layouts[j];
        for (m.loc.layoutEntries(sig), 0..) |he, h| if (he.kind == .cell and c.flags[c.off[j] + h] & CMod.flag_m != 0) {
            try f.markHandles(args[j], sig, @intCast(h));
        };
    }
    for (0..@min(c.arity, args.len)) |j| {
        const fnc = c.fns[j] orelse continue;
        var sw: ?bool = null;
        for (fnc.supply) |srcs| for (srcs) |s| {
            if (s.kind != .param or s.a >= c.arity or s.a >= args.len) continue;
            const sig = c.layouts[s.a];
            const inner = try f.innerOf(sig);
            if (s.e >= inner.len or !inner[s.e]) continue;
            if (sw == null) sw = try f.fnSwitches(args[j], 0);
            if (!sw.?) continue;
            for (m.loc.layoutEntries(sig), 0..) |he, h| if (he.kind == .cell) {
                var ks: std.ArrayList(u32) = .empty;
                defer ks.deinit(f.gpa);
                try f.contentsAt(sig, @intCast(h), &ks);
                if (std.mem.indexOfScalar(u32, ks.items, s.e) != null) try f.markHandles(args[s.a], sig, @intCast(h));
            };
        };
    }
}

/// Whether the function value `v` can run other fibers when it runs: its
/// code makes a call where another fiber can run (`Contract.switches`). The
/// frame's own function parameter: no, here (its caller judges it). Any
/// other function: yes.
fn fnSwitches(f: *Frame, v: Val, depth: u32) Error!bool {
    if (v == v_none or v == v_outside) return false;
    if (depth > 8) return true;
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        for (0..n.b) |ki| if (try f.fnSwitches(f.lists.items[n.a + 2 * ki], depth + 1)) return true;
        return false;
    }
    if (try f.codeOf(v)) |code| return code.contract.switches;
    if (f.isFnRoot(f.ownFnRoot(v))) return false;
    return true;
}

/// Kernel §13 item 12, a writer: the known function `code` at `use` goes where
/// the walk does not follow it, and capture `k` holds handles of cells the
/// frame made. Where every handle of the capture is one of a tracked root
/// the frame made that nothing shared or marked, the closure writes or
/// renews the contents only through the cell's own rows, hands them to no
/// code that runs it, renews them with captures, its own cells and
/// `outside` only, and holds no value taken out of them across a switch
/// point (no mark), the capture is a writer (`Writer`): it is not shared,
/// and runs at each later switch point of the frame and at its end
/// (`runWriter`). Answers whether it is one.
fn registerWriter(f: *Frame, v: Val, code: Code, k: u32, site: u32) Error!bool {
    const m = f.m;
    const lc = code.contract;
    const j: u32 = @intCast(code.own_params + k);
    if (j >= lc.arity or code.inst == none) return false;
    if (f.nodes.items[v].tag != .closure) return false;
    if (m.isDraft(lc) or lc.casts or code.own_params + code.ncaps > lc.arity) return false;
    for (0..code.ncaps) |kc| if (lc.fns[code.own_params + kc] != null) return false;
    if (f.writesOwn(lc, code.own_params)) return false;
    const sig = lc.layouts[j];
    const inner = try f.innerOf(sig);
    if (inner.len == 0) return false;
    const ses = m.loc.layoutEntries(sig);
    // Only a function that writes the contents in place: one that only
    // stores into the cell or reads it gives the handle another holder, as
    // before, which costs it nothing.
    var writes = false;
    for (lc.flags[lc.off[j]..lc.off[j + 1]], 0..) |x, e| {
        if (x & CMod.flag_m != 0) return false;
        if ((inner[e] or ses[e].kind == .cell) and x & flag_e != 0) return false;
        if (inner[e] and x & flag_w != 0) writes = true;
    }
    if (!writes) return false;
    if (handsContents(lc, j, inner) or !capturedSrcs(lc, j, code.own_params, inner)) return false;
    // Its answer names nothing of the capture, nor does a renewal of another.
    for (lc.res) |srcs| for (srcs) |s| if (s.kind == .param and s.a == j) return false;
    for (0..lc.arity) |a| if (a != j) for (lc.off[a]..lc.off[a + 1]) |i| if (lc.renewAt(i)) |srcs| for (srcs) |s| if (s.kind == .param and s.a == j) return false;
    const capv = try f.capVal(code, k);
    var os: std.ArrayList([3]u32) = .empty;
    defer os.deinit(f.gpa);
    const start = f.atoms.items.len;
    defer f.atoms.shrinkRetainingCapacity(start);
    for (ses, 0..) |he, h| if (he.kind == .cell) {
        const s0 = f.atoms.items.len;
        _ = try f.argLeaves(capv, sig, @intCast(h), &.{}, false, &f.atoms);
        if (f.atoms.items.len == s0) return false;
    };
    for (f.atoms.items[start..]) |a| {
        const before = os.items.len;
        try f.cellOrigins(a, &os);
        if (os.items.len == before) return false;
    }
    for (os.items) |o| {
        const r = f.roots.items[o[0]];
        if (r.kind != .local or !r.tracked) return false;
        if (f.cell_shared.contains(.{ o[0], o[1] }) or f.cell_marked.contains(.{ o[0], o[1] })) return false;
    }
    const ci = f.nodes.items[v].a;
    for (os.items) |o| try f.writers.append(f.gpa, .{ .code = ci, .k = k, .o = o[0], .e = o[1], .site = site });
    return true;
}

/// Whether capture `k` of the known function `code` is a writer
/// (`registerWriter`): codes of one closure share its captures' run.
fn isWriter(f: *const Frame, code: Code, k: usize) bool {
    if (code.inst == none) return false;
    for (f.writers.items) |w| {
        const wc = f.codes.items[w.code];
        if (wc.inst == code.inst and wc.caps == code.caps and w.k == k) return true;
    }
    return false;
}

/// A run of writer `w` at the switch point `inst`, whose call reads `ops`
/// (kernel §13 item 12): as a call that runs the closure within (item 11),
/// it reads what it writes of the capture there, its write of the contents
/// is a demand at the call on the frame's latest version, judged against
/// the call's operands (but a handle read through itself, and a writer of
/// the cell, which writes it in its own fiber) and the closure's other
/// captures, of what an earlier run stored too, and its renewal makes a
/// version that keeps the old contents (it may not run here).
fn runWriter(f: *Frame, w: Writer, inst: u32, ops: []const Val, followed: []const bool) Error!void {
    const m = f.m;
    const code = f.codes.items[w.code];
    const lc = code.contract;
    const j: u32 = @intCast(code.own_params + w.k);
    const sig = lc.layouts[j];
    const inner = try f.innerOf(sig);
    const ses = m.loc.layoutEntries(sig);
    const n = lc.off[j + 1] - lc.off[j];
    const capv = try f.capVal(code, w.k);
    try f.readBy(capv, inst, sig, lc.flags[lc.off[j]..lc.off[j + 1]]);
    var others: std.ArrayList(Other) = .empty;
    defer others.deinit(f.gpa);
    for (ops, 0..) |o, oi| {
        if (o == v_none or o == v_outside or (oi < followed.len and followed[oi] and f.isHandleOf(o, w.o))) continue;
        if (f.nodes.items[o].tag == .closure) {
            // A closure reads a handle it captured where it runs.
            const oc = f.codes.items[f.nodes.items[o].a];
            for (0..oc.ncaps) |kc| {
                const cv = try f.capVal(oc, kc);
                if (!f.isHandleOf(cv, w.o) or keepsCapture(oc, kc)) try others.append(f.gpa, .{ .v = cv });
            }
            continue;
        }
        try others.append(f.gpa, .{ .v = o });
    }
    for (0..code.ncaps) |kc| {
        const jc = code.own_params + kc;
        if (kc == w.k or jc >= lc.arity) continue;
        try others.append(f.gpa, .{ .v = try f.capVal(code, kc), .sig = lc.layouts[jc], .flags = lc.flags[lc.off[jc]..lc.off[jc + 1]] });
    }
    for (0..n) |e| {
        if (!inner[e] or lc.flags[lc.off[j] + e] & flag_w == 0) continue;
        const wa: u32 = @intCast(f.atoms.items.len);
        const dup = try f.argLeaves(capv, sig, @intCast(e), &.{}, false, &f.atoms);
        try f.storedAtoms(code, j, @intCast(e));
        try f.demand(wa, .{
            .point = inst,
            .loc = ses[e].loc,
            .others = others.items,
            .dup = dup and !ses[e].single,
            .list_only = ses[e].kind == .list,
            .kind = .callsite,
        });
    }
    if (!lc.renews()) return;
    const args = try f.gpa.alloc(Val, lc.arity);
    defer f.gpa.free(args);
    @memset(args, v_none);
    for (0..code.ncaps) |kc| if (code.own_params + kc < lc.arity) {
        args[code.own_params + kc] = try f.capVal(code, kc);
    };
    const bsite: Site = .{ .inst = inst };
    const base: Use = .{ .kind = .call, .id = f.useId(), .key = w.site, .holder = code.id(), .c = lc, .args = args, .site = &bsite };
    var done: ?[]bool = null;
    defer if (done) |d| f.gpa.free(d);
    for (ses, 0..) |he, h| {
        if (he.kind != .cell) continue;
        if (done) |d| if (d[h]) continue;
        var ks: std.ArrayList(u32) = .empty;
        defer ks.deinit(f.gpa);
        try f.contentsAt(sig, @intCast(h), &ks);
        const renewed = for (ks.items) |x| {
            if (lc.renewAt(lc.off[j] + x) != null) break true;
        } else false;
        if (!renewed) continue;
        if (done == null) {
            done = try f.gpa.alloc(bool, ses.len);
            @memset(done.?, false);
        }
        for (ks.items) |x| done.?[x] = true;
        try f.renewHandle(&base, lc, j, @intCast(h), ks.items, capv, lc.casts, true, inst);
    }
}

/// At a return point (`?`, the end of the walk) whose answer is `v`: the
/// writers run there too, since they can run after the frame ends, while
/// its caller holds the answer.
fn writersAtReturn(f: *Frame, point: u32, v: Val) Error!void {
    if (f.writers.items.len == 0) return;
    try f.flushShare();
    for (0..f.writers.items.len) |i| try f.runWriter(f.writers.items[i], point, &.{v}, &.{});
}

/// At the end of the walk: a writer whose cell got another holder after it
/// was made one, whose handle the frame answers, or which a holder of the
/// cell marked (a callee handed the handle, a closure run within a call)
/// is refused where it went out of sight.
fn revokeWriters(f: *Frame) Error!void {
    if (f.writers.items.len == 0) return;
    try f.flushShare();
    var answered: std.ArrayList([3]u32) = .empty;
    defer answered.deinit(f.gpa);
    for (f.returns.items) |rv| {
        if (rv == v_none or rv == v_outside) continue;
        const start = f.atoms.items.len;
        defer f.atoms.shrinkRetainingCapacity(start);
        _ = try f.allLeaves(rv, &f.atoms);
        const xs = try f.gpa.dupe(Atom, f.atoms.items[start..]);
        defer f.gpa.free(xs);
        for (xs) |a| try f.cellOrigins(a, &answered);
    }
    for (f.writers.items) |w| {
        const key: [2]u32 = .{ w.o, w.e };
        const kept = for (answered.items) |o| {
            if (o[0] == w.o and o[1] == w.e) break true;
        } else false;
        const why: ?[]const u8 = if (f.cell_shared.contains(key)) "the cell gets another holder" else if (f.cell_marked.contains(key)) "a holder of the cell keeps a value taken out of it across a call where another fiber can run" else if (kept) "the frame answers the cell" else null;
        if (why) |text| try f.m.addRefusal(f, w.site, .call, try std.fmt.allocPrint(f.m.arena, "a function that writes the contents of a cell it captured runs in another fiber, and {s}", .{text}));
    }
}

// ---- calls -----------------------------------------------------------------------------

fn call(f: *Frame, inst: u32, mode: Mode) Error!Val {
    _ = mode;
    const m = f.m;
    const data = m.datas[inst];
    const args = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index);
    const callee = data.lhs;
    if (m.spreadOf(f.d, inst)) |sp| return f.spreadChain(inst, sp);
    if (args.len == 2 and m.isListAppend(inst)) return f.appendChain(inst);
    // A constructor is applied here; any other callee is evaluated below, as an
    // expression (`evalInner`, whose switch names every tag).
    if (m.tags[callee] == .ctor or m.tags[callee] == .ext_ctor) {
        const place = try m.placeOfInst(inst);
        var tmp: std.ArrayList(Kid) = .empty;
        defer tmp.deinit(f.gpa);
        var vals: std.ArrayList(Val) = .empty;
        defer vals.deinit(f.gpa);
        var known = true;
        for (args, 0..) |a, k| {
            const v = try f.ev(a.int());
            try vals.append(f.gpa, v);
            if (try m.ctorArgStep(callee, place, @intCast(k))) |s| {
                try tmp.append(f.gpa, .{ .step = s.word(), .val = v });
            } else known = false;
        }
        // A constructor that no row describes: no claim, and each cell of its arguments.
        if (!known) return f.unknownOf(place, vals.items);
        // A record alias's constructor builds the record (backend.md §4):
        // the value the literal it stands for makes, with its object and
        // its slots (kernel §11.2). As a construction of its fields
        // alone, its slots held no cell, and an update of it wrote none.
        if (m.isRecordPlace(place)) return f.recordOf(place, tmp.items, inst, v_none);
        return f.built(place, tmp.items);
    }
    // The callee, then the arguments in order.
    var code: ?Code = null;
    var fn_root: u32 = none;
    var callee_val: Val = v_none;
    // A markup primitive of the vocabulary (`pub markup map`), which each
    // lowering's runtime implements (`boundary.md` §9.4.8).
    var primitive = false;
    // A function of the top level has its contract; any other callee is an
    // expression, evaluated by `evalInner`, whose switch names every tag.
    if (m.tags[callee] == .top or m.tags[callee] == .ext_value) {
        f.noteWalked(callee);
        // The evidence of a call is at the call; that of a reference is at the reference.
        _ = try f.evidence(callee);
        _ = try f.evidence(inst);
        if (m.calleeOf(callee)) |t| {
            if (try m.declContract(t)) |c| code = .{ .contract = c, .decl = t, .own_params = c.arity };
            if (t[0] < m.in.birs.len and t[1] < m.in.birs[t[0]].decls.len) primitive = m.in.birs[t[0]].decls[t[1]].kind == .vocab_markup;
        }
    } else {
        callee_val = try f.eval(callee, .callee, false);
        const n = f.nodes.items[callee_val];
        switch (n.tag) {
            .closure => code = f.codes.items[n.a],
            .fnref => {
                if (try m.declContract(.{ n.a, n.b })) |c| code = .{ .contract = c, .decl = .{ n.a, n.b }, .own_params = c.arity };
            },
            .ref => fn_root = f.ownFnRoot(callee_val),
            .none, .outside, .built, .join, .unknown => {},
            .later => unreachable, // read through `capVal` only
        }
        // One of several functions, or a function with no contract: no
        // rule follows which code runs, so each of them goes to the `top` use.
        if (code == null and fn_root == none) try f.flowTop(callee_val, inst);
    }
    if (code) |c| if (c.contract.entry and args.len == 1) return f.entryCall(inst, c.decl, args[0].int());
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    // A later argument of a callee that the lowering can short-circuit (`&&`,
    // `||`: `alwaysRuns`) may not run: what it renews is joined with the
    // cells as they were (kernel §13).
    var cells_before: ?[]const [2]u32 = null;
    const all_run = m.tags[callee] == .top and !m.in.isCore(m.in.module);
    for (args, 0..) |a, k| {
        if (k == 1 and !all_run) cells_before = try f.saveCells();
        // An argument at a function parameter flows to that parameter's
        // contract (`apply`). The argument of an identity is the call's value.
        const is_fn = if (code) |c| k < c.contract.arity and (c.contract.fns[k] != null or f.identityCall(c)) else false;
        try vals.append(f.gpa, try f.eval(a.int(), if (is_fn) .fn_arg else .value, false));
    }
    if (cells_before) |before| {
        try f.flushShare();
        const after = (try f.saveCells()).?;
        try f.joinCells(&.{ after, before }, &.{});
    }
    // Another fiber can run inside the call (kernel §13 item 12).
    {
        try vals.append(f.gpa, callee_val);
        defer _ = vals.pop();
        try f.switchPoint(inst, vals.items, if (code) |c| c.contract else null);
    }
    const writers_before = f.writers.items.len;
    // A call in a hole of markup can run after the other holes (`markup`).
    f.call_inst = inst;
    f.call_vals = try f.gpa.dupe(Val, vals.items);
    const casts_before = f.casts;
    const result: Val = blk: {
        if (code) |c| break :blk try f.apply(inst, callee, c, vals.items, args);
        if (fn_root != none) break :blk try f.callParam(inst, callee, fn_root, vals.items, args);
        // A markup primitive answers markup (kernel §6.12): the answer holds
        // each argument, the markup it is handed is read only where the platform
        // renders it, and what else it is handed (`map`'s function) the runtime
        // keeps past the render, so that escapes.
        if (primitive) {
            for (args, vals.items) |a, v| if (!m.isMarkup(m.typeOfInst(a.int()))) try f.escape(v, inst);
            break :blk try f.unknownOf(try m.placeOfInst(inst), vals.items);
        }
        // Unknown code: it can keep each argument, and its answer can hold each of them and the callee's captures.
        for (vals.items) |v| try f.escape(v, inst);
        try f.escape(callee_val, inst);
        try vals.append(f.gpa, callee_val);
        break :blk try f.unknownResult(inst, vals.items);
    };
    // A writer that went out of sight at this call can run within it.
    if (f.writers.items.len > writers_before and f.switchAt(inst)) {
        const followed = try f.followedOps(vals.items.len, if (code) |c| c.contract else null);
        defer f.gpa.free(followed);
        for (writers_before..f.writers.items.len) |i| try f.runWriter(f.writers.items[i], inst, vals.items, followed);
    }
    const named = m.tags[callee] == .top or m.tags[callee] == .ext_value;
    try f.noteJsSite(.{ if (named) callee else none, inst }, vals.items, result, f.casts and !casts_before);
    return result;
}

/// A call or a method call that the walk applied, kept with what it was
/// handed and answered, where the module's bodies are read for JavaScript
/// (`Check.reachesJs`): its edges are judged by these values when the
/// frame's answer is known (`judgeJsSites`). It reads nothing now and
/// counts no work.
fn noteJsSite(f: *Frame, pos: [2]u32, vals: []const Val, result: Val, casts: bool) Error!void {
    if (f.m.js_seen.bit_length == 0) return;
    const start: u32 = @intCast(f.js_site_vals.items.len);
    try f.js_site_vals.appendSlice(f.gpa, vals);
    try f.js_sites.append(f.gpa, .{ .pos = pos, .vals = start, .nvals = @intCast(vals.len), .result = result, .casts = casts });
}

/// Which edges of this frame's calls can see a cell of its contract (kernel
/// §6 rule 10, *An edge counts only where what it can see reaches the
/// contract*), once its answer `answer` is known: a call counts where a
/// value it was handed can hold a location of a parameter, a capture or a
/// function parameter's answer, where a root it was handed or answered is
/// one the answer can hold, or where it made the frame cast. Each call's
/// instructions are marked seen in `Mod.js_seen`, and those that count in
/// `Mod.js_dirty`: a call seen by every walk and counted by none is one
/// whose JavaScript sees nothing the contract describes. It reads the
/// values as they are (`siteHolds`), with no step: it counts no work.
fn judgeJsSites(f: *Frame, answer: Val) Error!void {
    const m = f.m;
    if (m.js_seen.bit_length == 0 or f.js_sites.items.len == 0) return;
    var st: SiteScan = .{};
    defer st.deinit(f.gpa);
    try st.init(f.gpa, f.nodes.items.len, f.roots.items.len);
    // The roots the answer can hold.
    var in_answer = try std.DynamicBitSetUnmanaged.initEmpty(f.gpa, f.roots.items.len);
    defer in_answer.deinit(f.gpa);
    st.next();
    if (answer != v_none) _ = try f.siteHolds(answer, &st, null);
    for (st.found.items) |r| in_answer.set(r);
    for (f.js_sites.items) |s| {
        st.next();
        var counts = s.casts;
        for (f.js_site_vals.items[s.vals..][0..s.nvals]) |v| {
            if (counts) break;
            if (try f.siteHolds(v, &st, &in_answer)) counts = true;
        }
        if (!counts and s.result != v_none and try f.siteHolds(s.result, &st, &in_answer)) counts = true;
        for (s.pos) |p| if (p != none and p < m.js_seen.bit_length) {
            m.js_seen.set(p);
            if (counts) m.js_dirty.set(p);
        };
    }
}

/// The state of `siteHolds`: the nodes and roots one scan visited (marked
/// by `gen`), and the roots it found.
const SiteScan = struct {
    gen: u32 = 0,
    node_gen: []u32 = &.{},
    root_gen: []u32 = &.{},
    found: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(u32) = .empty,

    fn init(s: *SiteScan, gpa: Allocator, nn: usize, nr: usize) Error!void {
        s.node_gen = try gpa.alloc(u32, nn);
        @memset(s.node_gen, 0);
        s.root_gen = try gpa.alloc(u32, nr);
        @memset(s.root_gen, 0);
    }
    fn deinit(s: *SiteScan, gpa: Allocator) void {
        gpa.free(s.node_gen);
        gpa.free(s.root_gen);
        s.found.deinit(gpa);
        s.stack.deinit(gpa);
    }
    fn next(s: *SiteScan) void {
        s.gen += 1;
        s.found.clearRetainingCapacity();
    }
};

/// Whether value `v` can hold a location of a parameter, a capture or a
/// function parameter's answer, or (where `answer` is given) a root of
/// `answer` (`judgeJsSites`). It follows the value's nodes, the root each
/// reference names, and the runs of every root it meets, at any depth: the
/// cells the walk says the value can hold. Each root it meets is appended
/// to `st.found`. With no `answer` it only collects them, and answers false.
/// A capture not yet bound holds what it will be bound to,
/// which is not known: it counts. No step: it counts no work, and reads no
/// memo of the walk's.
fn siteHolds(f: *Frame, v0: Val, st: *SiteScan, answer: ?*const std.DynamicBitSetUnmanaged) Error!bool {
    const m = f.m;
    // Nodes made after the scan's tables: none, since the walk is over.
    st.stack.clearRetainingCapacity();
    try st.stack.append(f.gpa, v0);
    while (st.stack.pop()) |v| {
        if (v >= st.node_gen.len) {
            if (answer != null) return true;
            continue;
        }
        if (st.node_gen[v] == st.gen) continue;
        st.node_gen[v] = st.gen;
        const n = f.nodes.items[v];
        switch (n.tag) {
            .none, .outside, .fnref => {},
            .ref => {
                const r = f.roots.items[n.a];
                switch (r.kind) {
                    // A part of a parameter with no location holds none of its cells.
                    .param, .capture, .answer => for (m.loc.paths.items[n.b].to_root) |re| {
                        if (re != none and answer != null) return true;
                    },
                    .outside => {},
                    .local, .fresh => if (try f.rootHolds(n.a, st, answer)) return true,
                }
            },
            .built => for (0..n.b) |ki| try st.stack.append(f.gpa, f.kids.items[n.a + ki].val),
            .join => for (0..n.b) |ki| try st.stack.append(f.gpa, f.lists.items[n.a + 2 * ki]),
            .unknown => for (0..n.b) |ki| try st.stack.append(f.gpa, f.lists.items[n.a + ki]),
            .closure => {
                const c = f.codes.items[n.a];
                for (0..c.ncaps) |k| {
                    const cv = f.lists.items[c.caps + k];
                    if (f.nodes.items[cv].tag == .later) {
                        if (answer != null) return true;
                        continue;
                    }
                    try st.stack.append(f.gpa, cv);
                }
            },
            .later => if (answer != null) return true,
        }
    }
    return false;
}

/// `siteHolds` of a root the frame made, or a cell a callee made: the root
/// is held, and so is every cell of the runs of its entries.
fn rootHolds(f: *Frame, root0: u32, st: *SiteScan, answer: ?*const std.DynamicBitSetUnmanaged) Error!bool {
    const m = f.m;
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(f.gpa);
    try roots.append(f.gpa, root0);
    while (roots.pop()) |root| {
        if (root >= st.root_gen.len) {
            if (answer != null) return true;
            continue;
        }
        if (st.root_gen[root] == st.gen) continue;
        st.root_gen[root] = st.gen;
        try st.found.append(f.gpa, root);
        if (answer) |a| if (a.isSet(root)) return true;
        const r = f.roots.items[root];
        switch (r.kind) {
            .param, .capture, .answer => if (answer != null) return true,
            .outside, .fresh => {},
            .local => for (0..m.loc.layouts.items[r.layout].len) |i| {
                const ent = f.rents.items[r.ent + i];
                for (f.atoms.items[ent.start..][0..ent.len]) |x| {
                    const xr = f.roots.items[x.root];
                    switch (xr.kind) {
                        .outside => {},
                        // A run's atom names a location.
                        .param, .capture, .answer => if (answer != null) return true,
                        .local, .fresh => try roots.append(f.gpa, x.root),
                    }
                }
            },
        }
    }
    return false;
}

/// A code binding whose rounds run, named in a walk: the code itself, or
/// another member of its group (`solveCodes`). It is the known function
/// with its contract so far and the values that it captured, as this frame
/// has them. So a call of it, and each place that it goes to, is judged as
/// for any known function, and no member holds another.
fn memberValue(f: *Frame, local: u32, inst: u32) Error!Val {
    const m = f.m;
    const b = m.lcode[f.d.locals_start + local];
    if (b != none) {
        const mb = f.memberOf(b);
        m.recalled[mb.inst] = true;
        if (m.code_contract[mb.inst]) |c| {
            const caps = m.code_caps[mb.inst];
            if (c.arity == mb.params.len + caps.len) {
                // The captures of the last round, in its order: the same values in each call.
                var tmp: std.ArrayList(Val) = .empty;
                defer tmp.deinit(f.gpa);
                for (caps) |l| {
                    const abs = f.d.locals_start + l;
                    try tmp.append(f.gpa, if (m.lframe[abs] != f.id) try f.capture(l) else m.lv[abs]);
                }
                const start: u32 = @intCast(f.lists.items.len);
                try f.lists.appendSlice(f.gpa, tmp.items);
                try f.codes.append(f.gpa, .{ .contract = c, .caps = start, .ncaps = @intCast(caps.len), .inst = mb.inst, .own_params = @intCast(mb.params.len) });
                return f.node(.{ .tag = .closure, .place = try m.placeOfLocal(f.d, local), .a = @intCast(f.codes.items.len - 1) });
            }
        }
    }
    // No contract to read: the walk gives up on the declaration.
    return f.giveUp(inst);
}

/// A method call, `x.m a` or an operator (`==`, `<`, …): the dispatch table
/// says which code runs (kernel §6.11, *no fact by a name*). A declaration
/// of the program is a call of its contract, as any call. A function the
/// compiler derives (`eq`, `compare` of a type that declares none, a codec)
/// reads its operands, and calls its evidence and the methods of the parts
/// of its type: each of those is judged where the walk cannot follow it
/// (`evidence`), so the read is all that the derived code does with them.
/// A receiver's field, and a target the table does not name, is unknown code.
fn methodCall(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    const mc = m.bir.extraData(@fromBackingInt(data.rhs), Bir.MethodCall);
    const args = m.bir.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
    const Target = enum { decl, reads, unknown };
    var target: Target = .unknown;
    var code: ?Code = null;
    if (m.in.dispatch) |dt| if (dt.siteOf(@fromBackingInt(inst))) |site| if (site.callee.unwrap()) |ti| switch (dt.term(ti)) {
        .top, .ext => if (m.methodTarget(inst)) |t| {
            target = .decl;
            if (try m.declContract(t)) |c| {
                if (c.arity == args.len + 1) code = .{ .contract = c, .decl = t, .own_params = c.arity };
            }
        },
        // Code of the compiler's own: it reads its operands (language.md
        // §6.5). What it calls — its evidence, and the declared methods of
        // the parts of its type at any depth — `evidence` judged: each one
        // that writes or keeps is refused. An evidence parameter (`a.eq`
        // under `where a.eq`) is a function the caller handed, and judged
        // at that call. So the read is all that is left.
        .derived, .ext_derived, .codec, .primitive, .undetermined, .param => target = .reads,
        .field, .identity, .text => {},
    };
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    var all: std.ArrayList(Inst.Index) = .empty;
    defer all.deinit(f.gpa);
    try all.append(f.gpa, @fromBackingInt(data.lhs));
    try all.appendSlice(f.gpa, args);
    for (all.items, 0..) |a, k| {
        // As in `call`: an argument at a function parameter flows to that parameter's contract.
        const is_fn = if (code) |c| c.contract.fns[k] != null else false;
        try vals.append(f.gpa, try f.eval(a.int(), if (is_fn) .fn_arg else .value, false));
    }
    const derived = try f.evidence(inst);
    // Another fiber can run inside the call (kernel §13 item 12).
    try f.switchPoint(inst, vals.items, if (code) |c| c.contract else null);
    const writers_before = f.writers.items.len;
    const casts_before = f.casts;
    const result: Val = blk: {
        switch (target) {
            .reads => {
                for (vals.items) |v| try f.readAll(v, inst);
                try f.derivedEffect(inst, derived, vals.items, all.items);
                break :blk try f.unknownResult(inst, vals.items);
            },
            .decl, .unknown => {},
        }
        if (code) |c| break :blk try f.apply(inst, inst, c, vals.items, all.items);
        for (vals.items) |v| try f.escape(v, inst);
        break :blk try f.unknownResult(inst, vals.items);
    };
    if (f.writers.items.len > writers_before and f.switchAt(inst)) {
        const followed = try f.followedOps(vals.items.len, if (code) |c| c.contract else null);
        defer f.gpa.free(followed);
        for (writers_before..f.writers.items.len) |i| try f.runWriter(f.writers.items[i], inst, vals.items, followed);
    }
    try f.noteJsSite(.{ inst, none }, vals.items, result, f.casts and !casts_before);
    return result;
}

/// Code that the checker does not follow at the dispatch site `inst` (kernel
/// §6.11). A function handed as evidence (`where`) is called any number of
/// times with values that it does not own: one that writes or keeps its
/// parameter, or has no contract, is refused. A callee that the compiler
/// derives (`eq`, `compare` of a type that declares none, a codec) calls
/// the methods of the parts of its type directly, at any depth
/// (`static-dispatch-spike.md` §3.3), once for each part of its operands:
/// what those can do is the answer, which the caller applies to the operands
/// (`derivedEffect`). The functions are every edge of the site's terms,
/// through the body of each derived row (`Mod.termsInfo`), each row once;
/// another module's derived row is read by the fact that module published
/// (`Mod.edgeEffect`).
fn evidence(f: *Frame, inst: u32) Error!CMod.Effect {
    return f.evidenceAt(inst, false);
}

/// `evidence`; with `with_decl`, a callee that is a declaration is read as
/// a derived callee too: the site runs it where the walk does not apply its
/// contract (`type_dispatch`).
fn evidenceAt(f: *Frame, inst: u32, with_decl: bool) Error!CMod.Effect {
    const m = f.m;
    const dt = m.in.dispatch orelse return .{};
    if (dt.sites.len == 0) return .{};
    const site = dt.siteOf(@fromBackingInt(inst)) orelse return .{};
    var roots: std.ArrayList(Dispatch.TermIndex) = .empty;
    defer roots.deinit(f.gpa);
    // A callee of a declaration is applied with its contract (`call`,
    // `methodCall`); any other callee is code of the compiler's own.
    if (site.callee.unwrap()) |ti| switch (dt.term(ti)) {
        .top, .ext => if (with_decl) try roots.append(f.gpa, ti),
        .derived, .ext_derived, .codec, .primitive, .undetermined, .param, .field, .identity, .text => try roots.append(f.gpa, ti),
    };
    const ncallee = roots.items.len;
    try roots.appendSlice(f.gpa, dt.argsAt(site.evidence));
    const x = (try m.termsInfo(roots.items[0..ncallee])).effect;
    // Each text of an edge of the evidence that can do something, once.
    const texts = (try m.termsInfo(roots.items[ncallee..])).texts;
    for ([_]u4{ 1, 2, 4, 8 }) |b| if (texts & b != 0) try m.addEvidenceRefusal(f, inst, Check.RowInfo.text(b));
    return x;
}

/// What a derived callee with effect `x` does with its operands `vals`
/// (kernel §6.11): each method it calls is handed a part of them, once. So
/// where one can keep what it is handed, or is unknown code, each operand
/// escapes; then, where one can write, every cell of each operand is a
/// demand, with the other operands as the other operands of the call. A
/// cell at two places of the operands is refused (`element`): the derived
/// code reads the second place after the method wrote the first.
fn derivedEffect(f: *Frame, inst: u32, x: CMod.Effect, vals: []const Val, arg_insts: []const Inst.Index) Error!void {
    // A method that writes what it handed a function parameter: the derived
    // code hands it the default, which keeps it (kernel §6.8).
    if (x.keeps or x.no_contract or x.rewrites) for (vals) |v| try f.escape(v, inst);
    if (!x.writes) return;
    const others = try f.gpa.alloc(Other, vals.len);
    defer f.gpa.free(others);
    for (others, vals) |*o, v| o.* = .{ .v = v };
    for (vals, 0..) |v, k| {
        const w: u32 = @intCast(f.atoms.items.len);
        const dup = try f.operandLeaves(v, &f.atoms);
        if (f.atoms.items.len == w) continue;
        const rest = try f.gpa.alloc(Other, vals.len - 1);
        var ri: usize = 0;
        for (others, 0..) |o, ok| if (ok != k) {
            rest[ri] = o;
            ri += 1;
        };
        try f.demand(w, .{ .point = inst, .kind = .callsite, .callee_inst = inst, .base_inst = if (k < arg_insts.len) arg_insts[k].int() else none, .others = rest, .dup = dup });
    }
}

/// Every cell of `v`, appended to `out`, and whether one of them can be at
/// two places of it: twice at one location, or at two of its locations.
fn operandLeaves(f: *Frame, v: Val, out: *std.ArrayList(Atom)) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .outside, .closure, .unknown => {
            _ = try f.allLeaves(v, out);
            // No claim: a cell can be anywhere in it.
            return n.tag != .outside;
        },
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    const start = out.items.len;
    var dup = false;
    const len = try f.layoutLen(n.place);
    var runs: std.ArrayList([2]usize) = .empty;
    defer runs.deinit(f.gpa);
    for (0..len) |e| {
        const at = out.items.len;
        if (try f.leaves(v, @intCast(e), out)) dup = true;
        try runs.append(f.gpa, .{ at, out.items.len });
    }
    // Only two entries that each hold an atom can share a cell: each pair of
    // them costs its comparisons (`dupOverlap`, kernel §8), and past the
    // budget they share.
    var held: std.ArrayList([2]usize) = .empty;
    defer held.deinit(f.gpa);
    for (runs.items) |r| if (r[1] > r[0]) try held.append(f.gpa, r);
    // A large set is tested by `runsShare`, linear in its atoms.
    const total = out.items.len - start;
    if (total > share_small or safety) {
        var rs: std.ArrayList([2]u32) = .empty;
        defer rs.deinit(f.gpa);
        for (held.items) |r| try rs.append(f.gpa, .{ @intCast(r[0]), @intCast(r[1]) });
        if (total > share_small) {
            if (try f.runsShare(out.items, rs.items, null)) dup = true;
            held.clearRetainingCapacity();
        } else if (held.items.len > 1) try f.checkShare(out.items, rs.items, null);
    }
    pairs: for (held.items, 0..) |r1, i| {
        for (held.items[i + 1 ..]) |r2| if (f.dupOverlap(out.items[r1[0]..r1[1]], out.items[r2[0]..r2[1]])) {
            dup = true;
            break :pairs;
        };
    }
    return dup;
}

/// The atoms of argument `v` at the callee's entry `se` of the signature
/// layout `sig`. With `suffix`, only the part at that suffix below the entry
/// (a function writes a part of what a type variable stands for). With
/// `deep`, each cell below that part too. The entries of `v` that this
/// asks for are one set (`leavesOwn`).
fn argLeaves(f: *Frame, v: Val, sig: u32, se: u32, suffix: []const u64, deep: bool, out: *std.ArrayList(Atom)) Error!bool {
    var ks: Entries = .{};
    f.coarse_hit = false;
    f.slot_lost = false;
    if (!try f.argEntries(v, sig, se, suffix, deep, &ks)) return f.leaves(v, 0, out);
    // A slot of the record at the argument's root that its own place has no
    // slot for: no cell of the frame names the object (`rootSlotLost`).
    if (f.slot_lost) try out.append(f.gpa, outside_atom);
    const coarse_hit = f.coarse_hit;
    const dup = try f.leavesOwn(v, ks.slice(), out);
    return dup or coarse_hit;
}

/// Whether layout `own` (an argument's) holds the record object whose slot
/// is asked at the label path `asked` (from the argument's root): a slot at
/// that path, a wide entry at or above it, or, where the asked path or a slot
/// of the field is in the deep level of a cycle, a slot of the field: the
/// call map pairs a cycle's deep level with its entry level, so a label path
/// there is no test (kernel §4.1). A record's object is a cell only where a
/// layout names its slots (kernel §11.1, §3.4). It scans `own` (kernel §8).
fn slotHeld(f: *Frame, own: u32, asked: []const u64) Error!bool {
    // The layout is indexed once in the frame (`SlotIndex`), and a question
    // costs the depth of its label path, not a scan of the layout: a call
    // asks it for each source and each slot of its answer (kernel §8;
    // research report 159). The answer is the scan's.
    const t = &f.m.loc;
    const ix = try f.slotIndex(own);
    const last: Loc.Label = @bitCast(asked[asked.len - 1]);
    _ = f.charge(Loc.lookup_units * (asked.len + 1));
    const es = t.layoutEntries(own);
    var asked_cyc = false;
    var at: ?u32 = 0;
    var ans = false;
    // A wide entry at the root, or at a prefix of the path, holds the record.
    if (t.indexOf(own, 0) != none and es[t.indexOf(own, 0)].kind.wide()) ans = true;
    for (asked) |w| {
        const l: Loc.Label = @bitCast(w);
        if (l.cyc) asked_cyc = true;
        if (at) |x| at = t.find(x, w);
        if (at) |x| {
            const i = t.indexOf(own, x);
            if (i != none and es[i].kind.wide()) ans = true;
        }
    }
    // A slot at the path.
    if (at) |x| if (t.indexOf(own, x) != none) {
        ans = true;
    };
    // A slot of the field in the deep level of a cycle, or any slot of the
    // field where the path asked is in one.
    if (!ans) {
        if (std.mem.indexOfScalar(u32, ix.cyc, last.payload) != null) ans = true;
        if (asked_cyc and std.mem.indexOfScalar(u32, ix.any, last.payload) != null) ans = true;
    }
    if (std.debug.runtime_safety and es.len <= 256) {
        const units = f.m.steps;
        const module_units = f.m.module_units;
        const over = f.m.steps_over;
        const scanned = try f.slotHeldScan(own, asked);
        f.m.steps = units;
        f.m.module_units = module_units;
        f.m.steps_over = over;
        std.debug.assert(scanned == ans);
    }
    return ans;
}

/// Per layout of the frame (`slotHeld`): the field ranks of its record slots
/// that are not wide (`any`), and of those with a step of a cycle on their
/// path (`cyc`), each once.
const SlotIndex = struct { any: []const u32, cyc: []const u32 };

fn slotIndex(f: *Frame, own: u32) Error!*const SlotIndex {
    if (own < f.slot_index.items.len) if (f.slot_index.items[own]) |x| return x;
    const t = &f.m.loc;
    const es = t.layoutEntries(own);
    var any: std.ArrayList(u32) = .empty;
    var cyc: std.ArrayList(u32) = .empty;
    // Built once for each layout in a frame; it costs the scan it replaces (kernel §8).
    _ = f.charge(Loc.scanUnits(es.len));
    for (es) |oe| {
        if (oe.kind.wide() or oe.loc == 0) continue;
        const ol: Loc.Label = @bitCast(t.loc_label.items[oe.loc]);
        if (ol.kind != .fslot) continue;
        const rank: u32 = ol.payload;
        if (std.mem.indexOfScalar(u32, any.items, rank) == null) try any.append(f.gpa, rank);
        var x = oe.loc;
        const in_cycle = while (x != 0) : (x = t.loc_parent.items[x]) {
            const pl: Loc.Label = @bitCast(t.loc_label.items[x]);
            if (pl.cyc) break true;
        } else false;
        _ = f.charge(Loc.scanUnits(t.loc_depth.items[oe.loc]));
        if (in_cycle and std.mem.indexOfScalar(u32, cyc.items, rank) == null) try cyc.append(f.gpa, rank);
    }
    const x = try f.gpa.create(SlotIndex);
    x.* = .{ .any = any.items, .cyc = cyc.items };
    if (own >= f.slot_index.items.len) try f.slot_index.appendNTimes(f.gpa, null, own + 1 - f.slot_index.items.len);
    f.slot_index.items[own] = x;
    return x;
}

/// `slotHeld`, by a scan of `own`: the reading of kernel §3.4 that the
/// index answers, kept as its check in safe builds.
fn slotHeldScan(f: *Frame, own: u32, asked: []const u64) Error!bool {
    const t = &f.m.loc;
    const last: Loc.Label = @bitCast(asked[asked.len - 1]);
    var at: ?u32 = 0;
    var asked_cyc = false;
    for (asked) |w| {
        const l: Loc.Label = @bitCast(w);
        if (l.cyc) asked_cyc = true;
        if (at) |x| at = t.find(x, w);
    }
    const oes = t.layoutEntries(own);
    _ = f.charge(Loc.scanUnits(oes.len) + asked.len);
    var ls: std.ArrayList(u64) = .empty;
    defer ls.deinit(f.gpa);
    for (oes) |oe| {
        if (at) |x| if (oe.loc == x) return true;
        if (oe.kind.wide()) {
            if (oe.loc == 0) return true;
            ls.clearRetainingCapacity();
            try t.labels(oe.loc, &ls, f.gpa);
            _ = f.charge(Loc.scanUnits(ls.items.len));
            if (ls.items.len <= asked.len and std.mem.eql(u64, ls.items, asked[0..ls.items.len])) return true;
            continue;
        }
        if (oe.loc == 0) continue;
        const ol: Loc.Label = @bitCast(t.loc_label.items[oe.loc]);
        if (ol.kind != .fslot or ol.payload != last.payload) continue;
        if (asked_cyc or ol.cyc) return true;
        var x = oe.loc;
        const in_cycle = while (x != 0) : (x = t.loc_parent.items[x]) {
            const pl: Loc.Label = @bitCast(t.loc_label.items[x]);
            if (pl.cyc) break true;
        } else false;
        _ = f.charge(Loc.scanUnits(t.loc_depth.items[oe.loc]));
        if (in_cycle) return true;
    }
    return false;
}

/// Whether the caller's slot at `e_loc` of an answer that a callee casts to
/// (`pairedLeaves`: the contract pairs the parameter location `ploc` with
/// the answer location `rentry`, one of them wide) is of an object no cell
/// of the argument `v` names: `v`'s own layout does not hold the record
/// whose slot it is (`slotHeld`). The record is `v`'s part at `ploc`, read
/// below `rentry` where `rentry` is wide, or itself where the slot is
/// `rentry` (a value of a type variable answered as a record).
fn castSlotLost(f: *Frame, v: Val, ploc: u32, rentry: Loc.Entry, e_loc: u32) Error!bool {
    const t = &f.m.loc;
    if (e_loc == 0) return false;
    const l: Loc.Label = @bitCast(t.loc_label.items[e_loc]);
    if (l.kind != .fslot) return false;
    const n = f.nodes.items[v];
    switch (n.tag) {
        // Its leaves hold `outside` already.
        .outside, .unknown => return false,
        .none, .fnref, .closure => return true,
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    var asked: std.ArrayList(u64) = .empty;
    defer asked.deinit(f.gpa);
    try t.labels(ploc, &asked, f.gpa);
    if (rentry.kind.wide()) {
        var below: std.ArrayList(u64) = .empty;
        defer below.deinit(f.gpa);
        try t.labels(e_loc, &below, f.gpa);
        const skip = t.loc_depth.items[rentry.loc];
        if (skip > below.items.len) return false;
        try asked.appendSlice(f.gpa, below.items[skip..]);
    } else try asked.append(f.gpa, l.word());
    if (asked.items.len == 0) return false;
    return !try f.slotHeld(try t.layoutOf(n.place), asked.items);
}

/// Whether a reading at the entries `js` of layout `view`, of a value whose
/// own place is `own`, asks for a field slot of the record at the value's
/// root that `own` has no slot for (`rootSlotLost`). The slots below the
/// root are asked of the parts that hold them, each at its own place
/// (`leavesOwnWalk`). It costs the entries asked (kernel §8).
fn slotsLost(f: *Frame, view: u32, own: PlaceId, js: []const u32) Error!bool {
    const ves = f.m.loc.layoutEntries(view);
    _ = f.charge(js.len);
    for (js) |j| {
        if (!f.isOwnSlot(ves[j].loc)) continue;
        const l: Loc.Label = @bitCast(f.m.loc.loc_label.items[ves[j].loc]);
        if (try f.rootSlotLost(own, l.payload)) return true;
    }
    return false;
}

/// Whether the slot of field `rank` of the record at the root of a value
/// whose own place is `own` is no cell of the value's own layout: `own` is
/// a tuple, a constructor, a list or another value that is no record, or a
/// record that does not name the field. A record's object is a cell only
/// where a layout names its slots (kernel §11.1); a tuple or a constructor
/// read as a record through `Js.to` is one JavaScript object whose slots no
/// cell names, so a write of one is a write of a cell outside every claim,
/// and a reading that found nothing there read "no cell" for "no claim"
/// (kernel §3.4; research report 147). A place that names no parts (a type
/// variable, an opaque type) is a wide entry, which holds the object.
fn rootSlotLost(f: *Frame, own: PlaceId, rank: u32) Error!bool {
    switch (f.m.places.kind(own)) {
        .@"var", .@"opaque", .cross => return false,
        .record => return try f.slotEntry(own, rank) == none,
        .tuple, .ctor, .list, .dict, .ref, .closure => return true,
    }
}

/// The entries of the argument `v`'s own layout that `argLeaves` reads,
/// added to `ks`. False when `v` has no entries to name: no object, no
/// claim, or a value whose every cell is at each location (`leaves` at 0).
fn argEntries(f: *Frame, v: Val, sig: u32, se: u32, suffix: []const u64, deep: bool, ks: *Entries) Error!bool {
    const m = f.m;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref, .outside, .closure, .unknown => return false,
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    const own = try m.loc.layoutOf(n.place);
    const cov = try m.loc.cover(sig, own);
    // The entries of `own` that the map sends to `se` or to every entry,
    // ascending: read off the map's index, not by a scan of the map.
    var hit: std.ArrayList(u32) = .empty;
    defer hit.deinit(f.gpa);
    try f.coverHits(sig, own, cov, se, &hit);
    // A wide entry of the argument's own layout that holds the cells at `se`,
    // which the map puts at another entry (`Loc.holes`): read too, and a
    // summary `se` is then no single place (kernel §3.4). The hits stay
    // ascending.
    if (try m.loc.holes(sig, own)) |h| {
        if (h.read[se] != none) {
            const k = h.read[se];
            var at: usize = 0;
            while (at < hit.items.len and hit.items[at] < k) at += 1;
            if (at == hit.items.len or hit.items[at] != k) try hit.insert(f.gpa, at, k);
        }
        if (h.above[se] != none and !m.loc.layoutEntries(sig)[se].single) f.coarse_hit = true;
    }
    // Each entry found is work of its own (kernel §8).
    _ = f.charge(hit.items.len);
    // Safe builds (kernel §9): the location asked is placed in the value's
    // own layout, as `leavesSet` checks (`checkPlaced`).
    if (std.debug.runtime_safety and hit.items.len == 0 and own != sig) try f.checkPlaced(sig, own, n.place, cov, try m.loc.holes(sig, own), &.{se});
    if (suffix.len != 0) {
        var want: ?u32 = m.loc.layoutEntries(sig)[se].loc;
        for (suffix) |l| {
            want = m.loc.find(want.?, l);
            if (want == null) break;
        }
        if (want == null) f.suffix_fallback = true;
        if (want) |wl| {
            var found: Entries = .{};
            // The cell at that part. `deep`: each cell below it too (the
            // part is a wide location of another reading of the type).
            const oes = m.loc.layoutEntries(own);
            for (hit.items) |k| if (oes[k].loc == wl or (deep and m.loc.isPrefix(wl, oes[k].loc))) {
                if (cov[k] != se and !deep) continue;
                try found.add(f.gpa, k);
            };
            if (found.slice().len == 0) f.suffix_fallback = true;
            if (found.slice().len != 0) {
                // A wide entry above that part holds its cells too (kernel §3.4).
                for (hit.items) |k| if ((oes[k].kind == .@"var" or oes[k].kind == .@"opaque") and oes[k].loc != wl and m.loc.isPrefix(oes[k].loc, wl)) try found.add(f.gpa, k);
                for (found.slice()) |k| try ks.add(f.gpa, k);
                return true;
            }
        }
        // A slot asked below a type variable of the signature (the caller's
        // view of what a cast answers) that the argument's own layout does
        // not hold (`slotHeld`): no cell names the object (kernel §3.4).
        const sl: Loc.Label = @bitCast(suffix[suffix.len - 1]);
        if (sl.kind == .fslot) {
            var asked: std.ArrayList(u64) = .empty;
            defer asked.deinit(f.gpa);
            try m.loc.labels(m.loc.layoutEntries(sig)[se].loc, &asked, f.gpa);
            try asked.appendSlice(f.gpa, suffix);
            if (!try f.slotHeld(own, asked.items)) f.slot_lost = true;
        }
    } else if (f.isOwnSlot(m.loc.layoutEntries(sig)[se].loc)) {
        // A slot of the record at the argument's root that its own place has
        // no slot for (`rootSlotLost`).
        const l: Loc.Label = @bitCast(m.loc.loc_label.items[m.loc.layoutEntries(sig)[se].loc]);
        if (try f.rootSlotLost(n.place, l.payload)) f.slot_lost = true;
    }
    for (hit.items) |k| {
        if (cov[k] == Loc.all) f.hit_all = true;
        try ks.add(f.gpa, k);
    }
    return true;
}

/// Per pair of layouts `sig`, `own`: the entries of `own` that the call map
/// `cov` sends to each entry of `sig`, and those it sends to every entry
/// (`Loc.all`), each ascending (`coverHits`).
const CoverIndex = struct { start: []u32, items: []u32, alls: []u32 };

/// The entries `k` of `own` with `Loc.hits(cov[k], se)`, ascending, in `out`.
fn coverHits(f: *Frame, sig: u32, own: u32, cov: []const u32, se: u32, out: *std.ArrayList(u32)) Error!void {
    const ci = blk: {
        if (f.cover_index.get(.{ sig, own })) |x| break :blk x;
        const ns = f.m.loc.layoutEntries(sig).len;
        const x = try f.gpa.create(CoverIndex);
        x.start = try f.gpa.alloc(u32, ns + 1);
        @memset(x.start, 0);
        var alls: std.ArrayList(u32) = .empty;
        for (cov, 0..) |c, k| {
            if (c == Loc.all) try alls.append(f.gpa, @intCast(k)) else if (c < ns) x.start[c + 1] += 1;
        }
        for (1..ns + 1) |i| x.start[i] += x.start[i - 1];
        x.items = try f.gpa.alloc(u32, x.start[ns]);
        const fill = try f.gpa.dupe(u32, x.start[0..ns]);
        defer f.gpa.free(fill);
        for (cov, 0..) |c, k| if (c != Loc.all and c < ns) {
            x.items[fill[c]] = @intCast(k);
            fill[c] += 1;
        };
        // Built once for each pair of layouts in a frame; it costs the map
        // and the signature's layout (kernel §8).
        _ = f.charge(2 * cov.len + ns);
        x.alls = alls.items;
        try f.cover_index.put(f.gpa, .{ sig, own }, x);
        break :blk x;
    };
    const mine = ci.items[ci.start[se]..ci.start[se + 1]];
    // Merge the two ascending runs.
    var i: usize = 0;
    var j: usize = 0;
    while (i < mine.len or j < ci.alls.len) {
        if (j == ci.alls.len or (i < mine.len and mine[i] < ci.alls[j])) {
            try out.append(f.gpa, mine[i]);
            i += 1;
        } else {
            try out.append(f.gpa, ci.alls[j]);
            j += 1;
        }
    }
    if (safety and cov.len <= 64) {
        // The index says what a scan of the map says.
        var n: usize = 0;
        for (cov) |c| if (Loc.hits(c, se)) {
            n += 1;
        };
        std.debug.assert(n == out.items.len);
    }
}

/// Apply contract `code.contract` to the arguments `vals` at the call `inst`.
fn apply(f: *Frame, inst: u32, callee: u32, code: Code, vals: []const Val, arg_insts: []const Inst.Index) Error!Val {
    return f.applyAt(inst, callee, code, vals, arg_insts, try f.m.placeOfInst(inst));
}

/// `apply`, with the answer at `place`: a call that the runtime makes, at
/// the markup that hands it its arguments (`runtimeCall`).
fn applyAt(f: *Frame, inst: u32, callee: u32, code: Code, vals: []const Val, arg_insts: []const Inst.Index, place: PlaceId) Error!Val {
    const m = f.m;
    const c = code.contract;
    // The values by the contract's parameters: the arguments, then the captures.
    var all: std.ArrayList(Val) = .empty;
    defer all.deinit(f.gpa);
    try all.appendSlice(f.gpa, vals);
    for (0..code.ncaps) |k| try all.append(f.gpa, try f.capVal(code, k));
    // Each argument read as it is now: a tracked root at its latest version
    // (kernel §13). A handle at two locations the callee reads apart has
    // another holder first (`cellsApart`).
    if (f.cells_any) {
        for (all.items) |*v| v.* = try f.cellsNow(v.*);
        if (all.items.len == c.arity) {
            try f.cellsApart(c, all.items, inst);
            for (all.items) |*v| v.* = try f.cellsNow(v.*);
        }
    }
    if (all.items.len != c.arity) {
        // A partial or an over-application: no rule follows it.
        for (all.items) |v| {
            try f.flowTop(v, inst);
            try f.escape(v, inst);
        }
        if (c.writes()) try m.addRefusal(f, inst, .call, "a function that writes its parameter is not called with all its arguments");
        // The code that runs it later hands its function parameters functions
        // in the default state, which keep what they are handed (kernel §6.8).
        const site: Site = .{ .inst = inst };
        const top: Use = .{ .kind = .top, .id = f.useId(), .key = inst, .site = &site, .code = code };
        try f.defaultParams(code, &top);
        return f.unknownResult(inst, all.items);
    }
    const args = all.items;
    // A function that answers its one parameter as it is (`Js.from`, `Js.to`,
    // `identity`): the value keeps its shape through a type that has none.
    // A function value stays the function that it is: nothing consumed it.
    // A contract that casts (`returned a → b`) answers the parameter
    // somewhere at or below its answer, not as it is: no words say where
    // (`[a]` is as true of it), so it is a call. `Js.from` and `Js.to` cast
    // by their types, and the build writes their calls as the argument
    // itself (`Mod.emitsArgument`): that fact, not the words, makes them
    // identities (kernel §3.4; research report 151).
    if (f.identityCall(code)) {
        try f.readBy(args[0], inst, c.layouts[0], c.flags);
        // A value read at another type of parts (a tuple or a constructor
        // read as a record, a list of tuples as a list of records) holds a
        // record's object that no cell of its own names: the answer is
        // `unknown` over it (kernel §3.4; research report 147).
        // The unknown answer names the argument's cells, but a part of it at a
        // type of no location is `outside`: the cells the reading has no
        // location for escape here too (`narrowed`; research report 150).
        if (try f.punned(args[0], if (arg_insts.len != 0) arg_insts[0].int() else none, place)) {
            try f.narrowed(args[0], inst, place, if (arg_insts.len != 0) arg_insts[0].int() else none);
            return f.unknownOf(place, args[0..1]);
        }
        // A value read at a type with fewer places than its own (a list
        // read as an `Int`, a list of lists as a list of numbers): the
        // cells at its own locations that no location of the reading names
        // are held by a value no reader can name, so they escape here
        // (kernel §3.4; research report 148).
        try f.narrowed(args[0], inst, place, if (arg_insts.len != 0) arg_insts[0].int() else none);
        return args[0];
    }
    // `Record.copy` (kernel §11): a new object whose fields hold the argument's values.
    if (c.record_copy and args.len == 1) return f.recordCopy(args[0], inst, place);
    // The flags of the contract are scanned three times below, for what it
    // lets escape, writes and reads (kernel §8).
    _ = f.charge(3 * Loc.scanUnits(c.flags.len / 4));
    const others = try f.gpa.alloc(Other, c.arity);
    for (others, 0..) |*o, j| o.* = .{ .v = args[j], .sig = c.layouts[j], .flags = c.flags[c.off[j]..c.off[j + 1]] };
    // What the callee lets escape, and the functions it is handed (each
    // flows to the contract of its parameter), before what it writes: a
    // write is judged against every escape of the call, including the one a
    // function's answer makes (`escapeAnswer`).
    for (0..c.arity) |j| {
        const sig = c.layouts[j];
        const n = c.off[j + 1] - c.off[j];
        // A closure the callee loses whose capture is a writer (kernel §13
        // item 12): its other captures escape, and the writer's handle runs
        // at the frame's switch points instead.
        const out_of_sight = if (c.fns[j]) |fnc| fnc.lost or for (0..n) |se| {
            if (c.flags[c.off[j] + se] & (flag_e | flag_a) != 0) break true;
        } else false else false;
        if (out_of_sight and f.cells_any and args[j] != v_none and f.nodes.items[args[j]].tag == .closure) {
            const lcode = f.codes.items[f.nodes.items[args[j]].a];
            var any = false;
            for (0..lcode.ncaps) |k| {
                if (f.isWriter(lcode, k) or try f.registerWriter(args[j], lcode, @intCast(k), inst)) any = true;
            }
            if (any) {
                const escapes_any = for (0..n) |se| {
                    if (c.flags[c.off[j] + se] & flag_e != 0) break true;
                } else false;
                if (escapes_any) for (0..lcode.ncaps) |k| if (!f.isWriter(lcode, k)) {
                    const start: u32 = @intCast(f.atoms.items.len);
                    _ = try f.allLeaves(try f.capVal(lcode, k), &f.atoms);
                    try f.noteEscape(start, inst);
                };
                continue;
            }
        }
        for (0..n) |se| if (c.flags[c.off[j] + se] & flag_e != 0) {
            const start: u32 = @intCast(f.atoms.items.len);
            _ = try f.argLeaves(args[j], sig, @intCast(se), &.{}, false, &f.atoms);
            try f.noteEscape(start, inst);
        };
    }
    const site: Site = .{ .inst = inst, .callee = callee, .arg_insts = arg_insts, .others = others };
    for (0..c.arity) |j| {
        const fnc = c.fns[j] orelse continue;
        const use: Use = .{ .kind = .call, .id = f.useId(), .key = inst, .holder = code.id(), .c = c, .fnc = fnc, .j = @intCast(j), .args = args, .site = &site };
        try f.flow(args[j], &use);
    }
    // The handles the callee marks, or hands to a function that can run
    // other fibers while it holds their contents (kernel §13 item 12).
    try f.applyMarks(c, args);
    // What the callee writes.
    for (0..c.arity) |j| {
        const sig = c.layouts[j];
        const n = c.off[j + 1] - c.off[j];
        for (0..n) |se| if (c.flags[c.off[j] + se] & flag_w != 0) {
            const w: u32 = @intCast(f.atoms.items.len);
            const dup = try f.argLeaves(args[j], sig, @intCast(se), &.{}, false, &f.atoms);
            // A written argument of no cell asks nothing, and is accepted;
            // but the slot of the record at its root is the record's object,
            // which a record always holds (kernel §11.2): a written one that
            // holds no cell is an object no cell names (a tuple of numbers
            // read as a record through `Js.to`), and has no claim (kernel
            // §3.4; research report 147).
            if (f.atoms.items.len == w and f.isOwnSlot(m.loc.layoutEntries(sig)[se].loc)) try f.atoms.append(f.gpa, outside_atom);
            try f.demand(w, .{
                .point = inst,
                .callee_inst = callee,
                .base_inst = if (j < arg_insts.len) arg_insts[j].int() else none,
                .loc = m.loc.layoutEntries(sig)[se].loc,
                .others = others,
                .arg = j,
                .se = @intCast(se),
                .dup = dup and !m.loc.layoutEntries(sig)[se].single,
                .list_only = m.loc.layoutEntries(sig)[se].kind == .list,
                .kind = if (code.decl[0] != none and m.isWorded(code.decl)) .writer else .callsite,
            });
        };
    }
    // What it reads.
    for (0..c.arity) |j| try f.readBy(args[j], inst, c.layouts[j], c.flags[c.off[j]..c.off[j + 1]]);
    // The level that the result's sources are read at: no function of it is in work.
    const base: Use = .{ .kind = .call, .id = f.useId(), .key = inst, .holder = code.id(), .c = c, .args = args, .site = &site };
    // The result.
    const layout = try m.loc.layoutOf(place);
    const es = m.loc.layoutEntries(layout);
    const cov = try m.loc.cover(c.layouts[c.arity], layout);
    // A location of the callee's result that no location of the caller's
    // reading holds (a result of a type variable read at `Int`, a `Maybe b`
    // read at `Maybe Int`): its cells escape at the call (`escapeUnplaced`).
    try f.escapeUnplaced(&base, c, cov, inst);
    // A callee that casts (`Contract.casts`), or a function value handed to
    // it that does, can answer at a type variable a value of another type: a
    // wide location of its result that the caller reads with a part of no
    // location below lets what it holds escape (`escapeHidden`).
    const casts = c.casts or try f.argsCast(c, args);
    if (casts) f.casts = true;
    if (casts) try f.escapeHidden(&base, c, cov, place, inst);
    if (c.casts and !(code.decl[0] != none and m.isWorded(code.decl))) try f.escapeHandedOff(c, code, args, &site, inst);
    try f.escapeWide(c, args, arg_insts, place, inst);
    // What the call leaves in the cells it is handed (kernel §13).
    if (c.renews()) try f.renewCells(&base, c, args, casts, inst);
    // An answer of a type with no location holds `outside` (`rootVal`).
    if (es.len == 0) return v_outside;
    // The contract is written for arguments of which no cell is at two
    // places (kernel §4.4). Where that does not hold, its claims that two
    // sources are two cells have no ground: no two locations of the result
    // are apart, and a summary location fed by two sources, or by an
    // answer, is `twice`.
    const args_apart = try f.argsApartAt(args, c, arg_insts) and !try f.argsSplit(args, c);
    // A new cell's handle that the answer holds is the answer's alone only
    // where the answer names it first: not one the call's renewals or flows
    // put in another holder (`cellResult`, kernel §13).
    const roots_before = f.roots.items.len;
    const root = try f.newRoot(.local, place, inst);
    f.roots.items[root].call = true;
    const ent0 = f.roots.items[root].ent;
    // Per entry: it holds the answer of a function parameter, which the callee's claims do not cover (`deriveLinear`).
    const has_answer = try f.gpa.alloc(bool, es.len);
    @memset(has_answer, false);
    // The atoms of an argument at an entry of its parameter are read once
    // for this result (`argLeavesKept`).
    const outer_gen = f.paired_gen;
    f.paired_gen = f.next_paired_gen;
    f.next_paired_gen += 1;
    defer f.paired_gen = outer_gen;
    for (0..es.len) |e| {
        const cr = cov[e];
        const start: u32 = @intCast(f.atoms.items.len);
        var st: SrcState = .{ .inst = inst, .typed = !casts };
        // No entry of the callee's result covers this one (its result type
        // has no object at all, and the caller's has): nothing is known of
        // it, so it is the lost answer, outside and every argument (§3.2).
        if (cr == none) {
            try f.lostAnswer(&base, &st);
            try f.uniqueTail(&f.atoms, start);
            f.rents.items[ent0 + e] = .{ .kind = .alias, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = !es[e].single };
            has_answer[e] = true;
            continue;
        }
        var sources: u32 = 0;
        var answers = false;
        if (cr == Loc.all) {
            for (c.res, 0..) |srcs, ri| {
                try f.expandSrcs(&base, srcs, c.layouts[c.arity], @intCast(ri), layout, @intCast(e), &st);
                for (srcs) |s| switch (s.kind) {
                    .param => sources += 1,
                    .answer => {
                        sources += 1;
                        answers = true;
                    },
                    .fresh, .outside, .twice => {},
                };
            }
        } else {
            try f.expandSrcs(&base, c.res[cr], c.layouts[c.arity], cr, layout, @intCast(e), &st);
            for (c.res[cr]) |s| switch (s.kind) {
                .param => sources += 1,
                .answer => {
                    sources += 1;
                    answers = true;
                },
                .fresh, .outside, .twice => {},
            };
        }
        // A written location that the callee answers has a new name; so has
        // an element that a trusted loop took out. Any other is the run.
        var kind: EKind = .alias;
        if (st.written) kind = .version;
        if (c.taken) kind = .taken;
        try f.uniqueTail(&f.atoms, start);
        const single = es[e].single;
        // One cell at two places of a summary location: it keeps its claim,
        // and its parts are not apart (kernel §4.4). An answer whose cells
        // are none that the holder handed on (each a cell the function made
        // in its run, or outside the frame; a captured cell is `twice`
        // already) holds no cell of the arguments, so a cell at two places
        // of them is at no two places of it.
        const twice = !single and (st.twice or (!args_apart and (sources > 1 or (answers and st.handed))));
        f.rents.items[ent0 + e] = .{ .kind = kind, .start = start, .len = @intCast(f.atoms.items.len - start), .twice = twice };
        has_answer[e] = answers;
    }
    // The callee's claim is about its own locations. Two locations of the
    // caller at one wide location of the callee's result (a type variable,
    // a `Js.Value` read as a pair) are one location to the callee, which says
    // nothing of whether one cell is at both: they are tested by their atoms,
    // as an answer's are (kernel §3.4, §4.4).
    var split: ?[]u32 = null;
    defer if (split) |x| f.gpa.free(x);
    if (es.len > 1) {
        const rses = m.loc.layoutEntries(c.layouts[c.arity]);
        const seen = try f.gpa.alloc(u32, rses.len);
        defer f.gpa.free(seen);
        @memset(seen, none);
        _ = f.charge(es.len + rses.len);
        for (cov, 0..) |cr, e| {
            // Every entry of the callee covers it: no claim does.
            if (cr == Loc.all) {
                has_answer[e] = true;
                continue;
            }
            if (cr == none or !rses[cr].kind.wide()) continue;
            if (seen[cr] == none) {
                seen[cr] = @intCast(e);
                continue;
            }
            const sp = split orelse blk: {
                const x = try f.gpa.alloc(u32, es.len);
                @memset(x, none);
                split = x;
                break :blk x;
            };
            sp[e] = cr;
            sp[seen[cr]] = cr;
        }
    }
    try f.deriveLinearSplit(root, !c.nonlinear and args_apart, has_answer, split);
    try f.cellResult(root, roots_before, inst);
    return f.rootVal(root);
}

/// A callee that casts can hand a cast value on as well as answer one: it
/// hands a function parameter a value read at the function's parameter
/// type (`feed x g = g (Js.to (Js.from x))`), whose part of no location the
/// caller's function reads at its own type and casts back; and the answer of
/// a function parameter that it answers can be below its answer (`ans g =
/// Js.to (Js.from (g ⊤))`), where `escapeHidden` reads the answer only as
/// the caller's reading names it. So at the call, each cell of an argument
/// that the contract hands a function parameter escapes (its supply), and
/// so does each cell a function argument's answer can hold where the
/// contract answers it (`escapeAnswer`): the pessimistic side, for a
/// contract that casts (research report 151's review).
fn escapeHandedOff(f: *Frame, c: *const Contract, code: Code, args: []const Val, site: *const Site, inst: u32) Error!void {
    for (0..c.arity) |j| {
        const fnc = c.fns[j] orelse continue;
        _ = f.charge(Loc.scanUnits(fnc.supply.len));
        for (fnc.supply) |srcs| for (srcs) |s| {
            // The answer of another function argument handed on (`feed h g =
            // g (Js.to (Js.from (h ⊤)))`): every cell it can hold escapes.
            if (s.kind == .answer and s.a < c.arity and s.a < args.len) if (c.fns[s.a]) |afn| {
                const ause: Use = .{ .kind = .call, .id = f.useId(), .key = inst, .holder = code.id(), .c = c, .fnc = afn, .j = s.a, .args = args, .site = site };
                try f.escapeAnswer(args[s.a], &ause);
                continue;
            };
            if (s.kind != .param or s.a >= args.len) continue;
            const start: u32 = @intCast(f.atoms.items.len);
            _ = try f.argLeaves(args[s.a], c.layouts[s.a], s.e, &.{}, false, &f.atoms);
            try f.noteEscape(start, inst);
        };
        const answered = blk: {
            for (c.res) |srcs| for (srcs) |s| if (s.kind == .answer and s.a == j) break :blk true;
            break :blk false;
        };
        if (!answered) continue;
        const use: Use = .{ .kind = .call, .id = f.useId(), .key = inst, .holder = code.id(), .c = c, .fnc = fnc, .j = @intCast(j), .args = args, .site = site };
        try f.escapeAnswer(args[j], &use);
    }
}

/// The locations of the callee's result that no location of the caller's
/// reading holds: `cov` maps no entry of the reading to them, and no entry
/// to `Loc.all`. The reading is an instance of the callee's result type, and
/// an instance can have fewer locations than the type (a type variable read
/// at `Int`, `Maybe b` at `Maybe Int`, a row at a record of no other field);
/// the answer is the same JavaScript value all the same, and a cast reads it
/// back at the type that has them. So what such a location holds — what
/// the arguments put there, a cell the callee made, the answer of a function
/// parameter — escapes at the call, as a walked cast's cells do (`narrowed`,
/// kernel §3.4): a location placed nowhere is never "holds nothing"
/// (research report 150). The scans are work (kernel §8).
fn escapeUnplaced(f: *Frame, base: *const Use, c: *const Contract, cov: []const u32, inst: u32) Error!void {
    const rsig = c.layouts[c.arity];
    const n = f.m.loc.layoutEntries(rsig).len;
    if (n == 0) return;
    _ = f.charge(Loc.scanUnits(cov.len) + Loc.scanUnits(n));
    const reached = try f.gpa.alloc(bool, n);
    defer f.gpa.free(reached);
    @memset(reached, false);
    for (cov) |cr| {
        if (cr == Loc.all) return;
        if (cr != none) reached[cr] = true;
    }
    for (0..n) |ri| {
        if (reached[ri] or !namesCell(c.res[ri])) continue;
        var st: SrcState = .{ .inst = inst };
        const start: u32 = @intCast(f.atoms.items.len);
        // Not a cast: the call reads each source as it reads it in place.
        try f.expandSrcs(base, c.res[ri], rsig, @intCast(ri), rsig, @intCast(ri), &st);
        // A written location that the callee answers there is a new name
        // of the written cells (`oldNames`); what escapes is the cells, at
        // any time.
        for (f.atoms.items[start..]) |*a| a.dead = none;
        try f.noteEscape(start, inst);
    }
}

/// A wide location of the callee's result that the caller reads at a type
/// with a part of no location below it (`Loc.holeAt` of the caller's place
/// at that path: `b` read as `List Int × Int`, `{ l : List Int, n : Int }`
/// or `List Int`), where the callee casts (`escapeHidden`'s caller): what
/// the callee put there can be at that part, where a reader finds `outside`,
/// so it escapes at the call. A location no reading location holds is
/// `escapeUnplaced`'s. A callee that does not cast answers at a type
/// variable only values of that variable, whose cells a caller's reading
/// names where the argument's own type does (kernel §3.4, research report
/// 150). The scans are work (kernel §8).
fn escapeHidden(f: *Frame, base: *const Use, c: *const Contract, cov: []const u32, place: PlaceId, inst: u32) Error!void {
    const rsig = c.layouts[c.arity];
    const rses = f.m.loc.layoutEntries(rsig);
    if (rses.len == 0 or cov.len == 0) return;
    _ = f.charge(Loc.scanUnits(cov.len) + Loc.scanUnits(rses.len));
    const reached = try f.gpa.alloc(bool, rses.len);
    defer f.gpa.free(reached);
    @memset(reached, false);
    for (cov) |cr| {
        if (cr == Loc.all) {
            @memset(reached, true);
            break;
        }
        if (cr != none) reached[cr] = true;
    }
    for (rses, 0..) |re, ri| {
        if (!reached[ri] or !re.kind.wide() or !namesCell(c.res[ri])) continue;
        if (!try f.m.loc.holeAt(place, re.loc)) continue;
        var st: SrcState = .{ .inst = inst };
        const start: u32 = @intCast(f.atoms.items.len);
        try f.allSrcs(base, c, c.res[ri], rsig, @intCast(ri), &st);
        for (f.atoms.items[start..]) |*a| a.dead = none;
        try f.noteEscape(start, inst);
    }
}

/// A callee whose result has a wide location (a type variable) that holds a
/// parameter location that is wide too (`a, Int → b`, `Js.Value → b`,
/// `Maybe a → b`, `List Js.Value → b`): the argument's part there is answered
/// as it is, read at the caller's type. Where both are roots the argument is
/// read as an identity's is (`narrowed`). Elsewhere, where the argument's
/// own type at that place is not the caller's type at the result's place
/// (`Loc.placeAt`), and the caller's has a part of no location below it,
/// the argument's cells there escape: honest code answers a value of the
/// variable at the variable, and the two places are one type (research
/// report 150; `Maybe.withDefault m []` read as `List Int` gives nothing).
/// A `Js.Value` at the parameter's place is what it was made from, not its
/// type (`partAt`: `Just (Js.from ( x, x ))` has the type `Maybe Js.Value`
/// and the pair as its part), and is read so (`narrowed`, `readAtVar`);
/// where no step names its part, a `Js.Value` the caller made of parts lets
/// them escape where the caller reads it at its own type variable (research
/// report 151).
fn escapeWide(f: *Frame, c: *const Contract, args: []const Val, arg_insts: []const Inst.Index, place: PlaceId, inst: u32) Error!void {
    const m = f.m;
    const rsig = c.layouts[c.arity];
    const rses = m.loc.layoutEntries(rsig);
    _ = f.charge(Loc.scanUnits(rses.len));
    for (rses, 0..) |re, ri| {
        if (!re.kind.wide()) continue;
        for (c.res[ri]) |s| {
            if (s.kind != .param or s.a >= args.len) continue;
            const psig = c.layouts[s.a];
            const pe = m.loc.layoutEntries(psig)[s.e];
            if (!pe.kind.wide()) continue;
            if (pe.loc == 0 and re.loc == 0) {
                try f.narrowed(args[s.a], inst, place, if (s.a < arg_insts.len) arg_insts[s.a].int() else none);
                continue;
            }
            // A value of no cell gives nothing; a function value's captures are
            // read where it flows (`flow`), not by its place.
            if (args[s.a] == v_none or args[s.a] == v_outside) continue;
            const read_at_or = try m.loc.placeAt(place, re.loc);
            // A `Js.Value` at the parameter's place is what it was made from
            // (`partAt`), read so. Where no step names the part (a cycle's
            // deep level, a row, the inside of a `Dict`), an argument the
            // caller made of parts (a construction, the answer of a call;
            // not a parameter, which the caller's caller reads) can hold its
            // cells below the `Js.Value`'s place, so they escape where the
            // reading has a type variable or a part of no location there.
            if (pe.kind == .@"opaque") {
                if (read_at_or) |r| if (try f.partAt(args[s.a], pe.loc)) |part| {
                    try f.narrowedAs(part, inst, r, try m.typeAt(m.typeOfInst(inst).unwrap(), re.loc), null);
                    continue;
                };
                const hides_here = if (read_at_or) |r| m.places.kind(r) == .@"var" or try m.loc.holeAt(place, re.loc) else true;
                if (hides_here and try f.madeOfParts(args[s.a], 0)) {
                    const start: u32 = @intCast(f.atoms.items.len);
                    _ = try f.argLeaves(args[s.a], psig, s.e, &.{}, false, &f.atoms);
                    try f.noteEscape(start, inst);
                    continue;
                }
            }
            const read_at = read_at_or orelse continue;
            const own = f.placeOfVal(args[s.a]) orelse continue;
            switch (m.places.kind(own)) {
                // A value of the caller's own type variable: the caller's caller
                // fills it in and reads it there.
                .closure, .@"var" => continue,
                .record, .tuple, .ctor, .list, .dict, .ref, .cross, .@"opaque" => {},
            }
            // A path the argument's own place does not name by steps (a deep
            // level of a cycle, a row, the inside of a `Dict`) is left to the
            // rules that read those (`cover`); research report 150 §11.
            const own_at = (try m.loc.placeAt(own, pe.loc)) orelse continue;
            if (own_at == read_at) continue;
            // Read at this frame's own type variable, a value of another type
            // than the variable: the frame casts, and its caller reads it
            // (`escapeHidden`). A `Js.Value` is read above.
            if (m.places.kind(read_at) == .@"var") switch (m.places.kind(own_at)) {
                .@"var", .@"opaque", .closure => {},
                .record, .tuple, .ctor, .list, .dict, .ref, .cross => f.casts = true,
            };
            if (!try f.hides(own_at, read_at)) continue;
            const start: u32 = @intCast(f.atoms.items.len);
            _ = try f.argLeaves(args[s.a], psig, s.e, &.{}, false, &f.atoms);
            try f.noteEscape(start, inst);
        }
    }
}

/// A value `v` read at a type `rty` of the place of its own type, where the
/// place has a type variable (`b`, `List b`): the place graph has one place
/// for every type variable, so the types must be one as well, or the frame
/// casts (`Contract.casts`). The value's type is what the walk knows of it
/// (`valIs`), or the type of the expression it is (`arg_ty`): a value has
/// the type of its expression unless an identity read it at another type,
/// and each identity of the frame was judged so already (this function, or
/// `readAtVar`), with the frame not casting. A value whose type is not known
/// is read as a cast, the pessimistic side (research report 151).
fn varAtVar(f: *Frame, v: Val, rty: ?Var, arg_ty: ?Var) void {
    if (f.casts) return;
    const rt = rty orelse {
        f.casts = true;
        return;
    };
    if (arg_ty) |at| if (f.m.sameType(at, rt, 0)) return;
    if (!f.valIs(v, rt, 0)) f.casts = true;
}
/// The type of a parameter's pattern in the body: a variable's local, or
/// the pattern's own type; `null` where neither is known.
fn patType(f: *Frame, pat: u32) ?Var {
    const m = f.m;
    if (pat == none) return null;
    if (m.tags[pat] == .pat_var) if (m.typeOfLocal(f.d, m.datas[pat].lhs).unwrap()) |t| return t;
    return m.typeOfInst(pat).unwrap();
}

/// Whether the walk knows that `v` is a value of type `t`: a part of a
/// parameter, a capture or a root the frame made, by the type of the root
/// (a parameter's pattern, a capture's local, the instruction that made it)
/// and the steps of the path (`Mod.typeAtPath`); a tuple or a record built
/// of parts of the types of `t`'s parts; a join of such arms. A value of no
/// cell (`none`, `outside`) holds nothing a type can hide. Else no.
fn valIs(f: *Frame, v: Val, t: Var, depth: u32) bool {
    if (depth > 8) return false;
    const m = f.m;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .outside => return true,
        .ref => {
            const r = f.roots.items[n.a];
            const at_root: ?Var = switch (r.kind) {
                // A parameter by the type of its pattern in the body (the
                // scheme's variables are other variables of the store).
                .param => f.patType(r.inst),
                .capture => if (r.index < f.param_ty.items.len) f.param_ty.items[r.index].unwrap() else null,
                .local, .answer => if (r.inst != none) m.typeOfInst(r.inst).unwrap() else null,
                .outside, .fresh => null,
            };
            const vt = m.typeAtPath(at_root orelse return false, r.path, n.b) orelse return false;
            return m.sameType(vt, t, 0);
        },
        .join => {
            for (0..n.b) |ki| if (!f.valIs(f.lists.items[n.a + 2 * ki], t, depth + 1)) return false;
            return true;
        },
        .built => {
            const store = m.in.store;
            _, const c = store.resolved(t);
            const s = switch (c) {
                .structure => |x| x,
                .flex, .rigid, .alias, .err => return false,
            };
            for (f.kids.items[n.a..][0..n.b]) |kid| {
                const st = Step.fromWord(kid.step);
                const pt: Var = switch (st.kind) {
                    .index => switch (s) {
                        .tuple => |r| blk: {
                            const xs = store.vars(r);
                            if (st.payload >= xs.len) return false;
                            break :blk xs[st.payload];
                        },
                        .unit, .empty_record, .func, .app, .record => return false,
                    },
                    .field => switch (s) {
                        .record => |r| blk: {
                            for (store.fields(r.fields)) |fd| {
                                const sym = @backingInt(fd.name);
                                if (sym < m.in.ranks.len and m.in.ranks[sym] == st.payload) break :blk fd.value;
                            }
                            return false;
                        },
                        .unit, .empty_record, .func, .app, .tuple => return false,
                    },
                    .ctor_arg, .elem, .contents, .env, .slot, .level, .row => return false,
                };
                if (!f.valIs(kid.val, pt, depth + 1)) return false;
            }
            return true;
        },
        .closure, .fnref, .unknown => return false,
        .later => unreachable, // read through `capVal` only
    }
}

/// The value `v` read at a type variable of the frame (`narrowed`,
/// `escapeWide`): a value of another type than the variable casts (the
/// contract says so, `Contract.casts`, and each caller reads it); a
/// `Js.Value` the frame made of parts lets them escape (`madeOfParts`); a
/// value of a type variable, or a `Js.Value` the caller handed, is read as
/// it is (kernel §3.4; research reports 150, 151).
fn readAtVar(f: *Frame, v: Val, inst: u32) Error!void {
    const own = f.placeOfVal(v) orelse return;
    switch (f.m.places.kind(own)) {
        .@"var" => {},
        .@"opaque" => if (try f.madeOfParts(v, 0)) {
            try f.escape(v, inst);
            if (std.debug.runtime_safety) try f.checkMadeEscaped(v);
        },
        .record, .tuple, .ctor, .list, .dict, .ref, .closure, .cross => f.casts = true,
    }
}

/// Safe builds (kernel §9): every cell of a `Js.Value` that the frame made of
/// parts and read at a type variable, or at a type with one below its place,
/// escaped (`readAtVar`, `narrowed`): no cell of the frame is below a
/// variable a caller fills in with a type of no location there. It reads
/// the leaves again and compares them with every escape of the frame, and
/// counts no work. With the escape turned off (research report 151's fault,
/// `Js.to (Js.array [ Js.from x ])` read at `b`), the first such read panics.
fn checkMadeEscaped(f: *Frame, v: Val) Error!void {
    const m = f.m;
    if (m.steps_over or f.failed) return;
    const steps = m.steps;
    const units = m.module_units;
    const over = m.steps_over;
    const failed = f.failed;
    var xs: std.ArrayList(Atom) = .empty;
    defer xs.deinit(f.gpa);
    _ = try f.allLeaves(v, &xs);
    m.steps = steps;
    m.module_units = units;
    m.steps_over = over;
    f.failed = failed;
    for (xs.items) |a| {
        if (a.root == 0) continue;
        const held = for (f.esc_atoms.items) |x| {
            if (f.overlap(x, a)) break true;
        } else false;
        if (!held) std.debug.panic("own3: a Js.Value made of parts and read at a type variable holds a cell of root {d} that did not escape (kernel §3.4, §9)", .{a.root});
    }
}

/// Whether `v`, a `Js.Value` of the frame, was made by the frame of parts it
/// holds below its place: a root the frame made (the answer of a call, of a
/// function parameter, a cell it made), a construction, a function value or
/// an `unknown`, that holds a cell other than `outside`; or a join with such
/// an arm. A parameter's or a capture's value, or a part of one, is the
/// caller's, as the caller made it (kernel §3.4, *What a value was made
/// from*; research report 151). The leaves are work (kernel §8).
fn madeOfParts(f: *Frame, v: Val, depth: u32) Error!bool {
    if (depth > 8) return true;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .outside, .fnref => return false,
        .join => {
            for (0..n.b) |ki| if (try f.madeOfParts(f.lists.items[n.a + 2 * ki], depth + 1)) return true;
            return false;
        },
        .ref => switch (f.roots.items[n.a].kind) {
            .param, .capture, .outside => return false,
            .local, .answer, .fresh => {},
        },
        .built, .closure, .unknown => {},
        .later => unreachable, // read through `capVal` only
    }
    const start = f.atoms.items.len;
    defer f.atoms.shrinkRetainingCapacity(start);
    _ = try f.allLeaves(v, &f.atoms);
    _ = f.charge(Loc.scanUnits(f.atoms.items.len - start));
    for (f.atoms.items[start..]) |a| if (a.root != 0) return true;
    return false;
}

/// The part of `v` at the location `loc` of another layout of its type (a
/// callee's parameter), step by step from the place of each part reached
/// (`Loc.stepOf`, `project`), or `null` where a label has no step of that
/// place (a slot, a row, a cycle's deep level, the inside of a `Dict`, a
/// function value's). It is the value the part was made from: a
/// construction's part is the value it was built of. Counted (kernel §8).
fn partAt(f: *Frame, v: Val, loc: u32) Error!?Val {
    if (loc == 0) return v;
    var ls: std.ArrayList(u64) = .empty;
    defer ls.deinit(f.gpa);
    try f.m.loc.labels(loc, &ls, f.gpa);
    _ = f.charge(Loc.scanUnits(ls.items.len));
    var cur = v;
    for (ls.items) |w| {
        if (cur == v_none or cur == v_outside) return cur;
        // A label of a cycle's deep level is one or more levels below, at a
        // depth no step of the value names: no part (the type is read).
        const l: Loc.Label = @bitCast(w);
        if (l.cyc or l.kind == .member) return null;
        const p = f.placeOfVal(cur) orelse return null;
        const s = f.m.loc.stepOf(p, w) orelse return null;
        cur = try f.project(cur, s);
    }
    return cur;
}

/// Whether a value of the place `own` read at the place `view` has a cell
/// that no reader can name: `narrowed`'s test, of types alone. A location
/// of `own`'s layout that no location of `view`'s is at or wide above, or
/// a wide one that `view` reads at a location that is not wide with a part
/// of no location below it. Two places of one type hide nothing.
fn hides(f: *Frame, own: PlaceId, view: PlaceId) Error!bool {
    const m = f.m;
    switch (m.places.kind(view)) {
        .@"var", .@"opaque" => return false,
        .record, .tuple, .ctor, .list, .dict, .ref, .closure, .cross => {},
    }
    const ol = try m.loc.layoutOf(own);
    const oes = m.loc.layoutEntries(ol);
    if (oes.len == 0) return false;
    const vl = try m.loc.layoutOf(view);
    const ves = m.loc.layoutEntries(vl);
    // One layout, location for location: one type read at itself.
    if (ol == vl) return false;
    if (oes.len == ves.len) {
        _ = f.charge(Loc.scanUnits(oes.len));
        for (oes, ves) |a, b| {
            if (a.loc != b.loc or a.kind != b.kind) break;
        } else return false;
    }
    const cov = try m.loc.cover(vl, ol);
    _ = f.charge(Loc.scanUnits(cov.len));
    for (cov, 0..) |c, k| {
        if (c == none or c == Loc.all) return true;
        if (oes[k].kind.wide() and !ves[c].kind.wide() and try m.loc.holeAt(view, oes[k].loc)) return true;
    }
    return false;
}

/// Whether a function value handed to a function parameter of the call is
/// known code that casts (`Contract.casts`): the callee answers its answers.
/// A function the frame was handed (a draft) is judged where the function
/// meets the frame's own holder (`escapeUnplacedAnswer`), and unknown code
/// escapes there already.
fn argsCast(f: *Frame, c: *const Contract, args: []const Val) Error!bool {
    for (0..@min(c.arity, args.len)) |j| {
        if (c.fns[j] == null) continue;
        if (try f.valCasts(args[j], 0)) return true;
    }
    return false;
}

fn valCasts(f: *Frame, v: Val, depth: u32) Error!bool {
    if (v == v_none or depth > 8) return depth > 8;
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        for (0..n.b) |ki| if (try f.valCasts(f.lists.items[n.a + 2 * ki], depth + 1)) return true;
        return false;
    }
    const code = (try f.codeOf(v)) orelse return false;
    return code.contract.casts;
}

/// Every cell that the sources `srcs` of the callee's result location `ri`
/// can name, appended to `f.atoms`: a parameter's every cell at its entry
/// (`argLeaves`), whatever part a reading would take of it; the others as
/// the call reads them (`expandSrcs`). What an escape of a location must
/// cover (research report 150).
fn allSrcs(f: *Frame, base: *const Use, c: *const Contract, srcs: []const Src, rsig: u32, ri: u32, st: *SrcState) Error!void {
    var others: std.ArrayList(Src) = .empty;
    defer others.deinit(f.gpa);
    for (srcs) |s| switch (s.kind) {
        .param => if (s.a < base.args.len) {
            // The argument's own type holds no cell at the parameter's
            // place (`List.sort xs` of a `List Int`: its elements): nothing.
            if (f.placeOfVal(base.args[s.a])) |own| {
                if (try f.m.loc.placeAt(own, f.m.loc.layoutEntries(c.layouts[s.a])[s.e].loc)) |at| {
                    if (f.m.places.holds(at).isEmpty()) continue;
                }
            }
            _ = try f.argLeaves(base.args[s.a], c.layouts[s.a], s.e, &.{}, false, &f.atoms);
        } else try others.append(f.gpa, s),
        .answer, .fresh, .outside, .twice => try others.append(f.gpa, s),
    };
    if (others.items.len != 0) try f.expandSrcs(base, others.items, rsig, ri, rsig, ri, st);
}

/// Whether a source of a contract's result names a cell of a frame: a
/// parameter's, the answer of a function parameter, or a cell the callee made.
fn namesCell(srcs: []const Src) bool {
    for (srcs) |s| switch (s.kind) {
        .param, .answer, .fresh => return true,
        // No cell of a frame.
        .outside, .twice => {},
    };
    return false;
}

/// Whether no cell is at two places of the arguments `args`: in two
/// arguments, or in two parts of one argument (`( q, q )`). A callee's
/// contract is written for arguments that are so, and its claims about two
/// sources of its result hold only then (`apply`).
fn argsApart(f: *Frame, args: []const Val) Error!bool {
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(f.gpa);
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    for (args) |v| if (!try f.partsOf(v, &buf, &runs, 0)) return false;
    return try f.runsApart(buf.items, runs.items);
}

/// `argsApart` for a call of contract `c`: where the contract reads a list
/// parameter only at the positions other than the one another parameter
/// names (`positionedParam`, kernel §6 rule 10, *A position*: `set`'s list
/// beside its stored value), its element at that position is in no part of
/// the result, and the callee's claims about the result do not rest on it.
/// So the argument's elements are read at the other positions of the match
/// of the argument and the index (`posKey`): a stored value that holds the
/// element the call replaces is apart from them.
fn argsApartAt(f: *Frame, args: []const Val, c: *const Contract, arg_insts: []const Inst.Index) Error!bool {
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(f.gpa);
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    for (args, 0..) |v, j| {
        const match = if (j < c.arity) if (positionedParam(f.m, c, j)) |q| (if (q < args.len and q < arg_insts.len) try f.posKey(v, arg_insts[q].int()) else none) else none else none;
        if (match == none) {
            if (!try f.partsOf(v, &buf, &runs, 0)) return false;
            continue;
        }
        // `posKey` read `v` as a part of a root that holds each cell once.
        const n = f.nodes.items[v];
        const m = f.m;
        const es = m.loc.layoutEntries(try m.loc.layoutOf(n.place));
        const pr = (try m.loc.proj(n.place, Step.elem)) orelse {
            if (!try f.partsOf(v, &buf, &runs, 0)) return false;
            continue;
        };
        // The scan of the layout is work (kernel §8).
        _ = f.charge(Loc.scanUnits(es.len) + pr.up.len);
        var elems: std.ArrayList(u32) = .empty;
        defer elems.deinit(f.gpa);
        var rest: std.ArrayList(u32) = .empty;
        defer rest.deinit(f.gpa);
        for (0..es.len) |e| {
            if (std.mem.indexOfScalar(u32, pr.up, @intCast(e)) != null) try elems.append(f.gpa, @intCast(e)) else try rest.append(f.gpa, @intCast(e));
        }
        const start: u32 = @intCast(buf.items.len);
        if (elems.items.len != 0) _ = try f.leavesOwn(v, elems.items, &buf);
        for (buf.items[start..]) |*a| if (a.root != 0) {
            a.pos = match << pos_bits | pos_other;
        };
        if (rest.items.len != 0) _ = try f.leavesOwn(v, rest.items, &buf);
        if (buf.items.len != start) try runs.append(f.gpa, .{ start, @intCast(buf.items.len) });
    }
    return try f.runsApart(buf.items, runs.items);
}

/// The parameter `q` whose position parameter `j`'s list is read beside
/// (kernel §6 rule 10, *A position*), where contract `c` holds parameter
/// `j` in its result and its supplies only at its storage (the location of
/// its root) and at its elements at the positions other than `q`'s
/// (`Src.p`), and at some such element. Else null.
fn positionedParam(m: *Mod, c: *const Contract, j: usize) ?usize {
    var q: ?usize = null;
    const pes = m.loc.layoutEntries(c.layouts[j]);
    const Scan = struct {
        fn one(srcs: []const Src, jj: usize, es: []const Loc.Entry, at: *?usize) bool {
            for (srcs) |s| {
                if (s.kind != .param or s.a != jj) continue;
                if (s.p == 0) {
                    if (s.e >= es.len or es[s.e].loc != 0) return false;
                    continue;
                }
                if ((s.p - 1) % 2 != pos_other) return false;
                const sq: usize = (s.p - 1) / 2;
                if (at.*) |x| if (x != sq) return false;
                at.* = sq;
            }
            return true;
        }
    };
    for (c.res) |srcs| if (!Scan.one(srcs, j, pes, &q)) return null;
    for (c.fns) |fo| if (fo) |g| for (g.supply) |srcs| if (!Scan.one(srcs, j, pes, &q)) return null;
    return q;
}

/// Whether an argument is read at its parameter's layout through a wide
/// entry of its own that stands for two locations of the parameter, or for
/// a summary location (`Loc.holes`, kernel §3.4): the callee sees one cell
/// at two places of it, which the argument's own layout cannot show apart.
/// The contract is written for arguments that are apart (kernel §4.4).
fn argsSplit(f: *Frame, args: []const Val, c: *const Contract) Error!bool {
    const m = f.m;
    for (args, 0..) |v, j| {
        if (j >= c.arity) break;
        const n = f.nodes.items[v];
        switch (n.tag) {
            .ref, .built, .join => {},
            .none, .fnref, .outside, .closure, .unknown => continue,
            .later => unreachable, // read through `capVal` only
        }
        const sig = c.layouts[j];
        const h = (try m.loc.holes(sig, try m.loc.layoutOf(n.place))) orelse continue;
        if (try splitAbove(m, sig, h)) return true;
    }
    return false;
}

/// Whether one wide entry of `holes` is above two entries of `view`, or
/// above a summary entry: one cell of it can be at two places of the view.
fn splitAbove(m: *Mod, view: u32, h: *const Loc.Holes) Error!bool {
    const ves = m.loc.layoutEntries(view);
    for (h.above, 0..) |k, j| {
        if (k == none) continue;
        if (!ves[j].single) return true;
        for (h.above[j + 1 ..]) |k2| if (k2 == k) return true;
    }
    return false;
}

/// Whether no cell is at two places of the one value `v`.
fn valueApart(f: *Frame, v: Val, depth: u32) Error!bool {
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(f.gpa);
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    if (!try f.partsOf(v, &buf, &runs, depth)) return false;
    return try f.runsApart(buf.items, runs.items);
}

fn runsApart(f: *const Frame, buf: []const Atom, runs: []const [2]u32) Error!bool {
    // A large set is tested by `runsShare`, linear in its atoms.
    var total: usize = 0;
    for (runs) |r| total += r[1] - r[0];
    if (total > share_small) return !try f.runsShare(buf, runs, null);
    try f.checkShare(buf, runs, null);
    // A run with no atom is apart from every run. The scan for each other
    // run is work of its own (kernel §8); past the budget the runs are not
    // apart.
    for (runs, 0..) |x, i| {
        if (x[1] == x[0]) continue;
        if (f.charge(runs.len - i)) return false;
        for (runs[i + 1 ..]) |y| if (y[1] > y[0] and f.dupOverlap(buf[x[0]..x[1]], buf[y[0]..y[1]])) return false;
    }
    return true;
}

/// The parts of the value `v` as runs of atoms. False when `v` cannot claim
/// that its own parts are apart. One case for each kind of value:
///
/// - no object, a function with no captured value, a value outside the
///   frame: no cell of the frame;
/// - a part of a root: one part. A root that the frame made says if its
///   parts are apart (`linear`); a parameter and a captured local are apart
///   by the rule that this function checks at each call: two parameters,
///   and two parts of one, are sources of the frame's result, and the caller
///   judges them with its own arguments. The answer of the frame's own
///   function parameter is one part too: its contract names it as an
///   answer, and the caller that knows the function reads what it holds;
/// - a tuple, a record or a constructor application: each item is a part,
///   and each item must be apart in itself. A nest that is too deep to
///   follow has no claim (a resource limit, on the pessimistic side);
/// - one of several values: each of them must be apart in itself. Two of
///   them are never one value, so together they are one part;
/// - a function value: what it captured is one part. An answer never has a
///   claim on a captured cell, so two captured locals that are one cell need
///   no check here;
/// - a value that the walk cannot follow (`unknown`): one cell can be at two.
fn partsOf(f: *Frame, v: Val, buf: *std.ArrayList(Atom), runs: *std.ArrayList([2]u32), depth: u32) Error!bool {
    if (f.tick()) return false;
    if (v == v_none or v == v_outside) return true;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .outside, .fnref => return true,
        .built => {
            if (depth >= 8) return false;
            for (0..n.b) |ki| if (!try f.partsOf(f.kids.items[n.a + ki].val, buf, runs, depth + 1)) return false;
            return true;
        },
        .join => {
            if (depth >= 8) return false;
            for (0..n.b) |ki| {
                if (!f.armLive(n, ki)) continue;
                if (!try f.valueApart(f.lists.items[n.a + 2 * ki], depth + 1)) return false;
            }
        },
        .ref => {
            const r = f.roots.items[n.a];
            if (r.kind == .local and !f.isLinear(n.a)) return false;
        },
        .closure => {},
        .unknown => {
            const start = buf.items.len;
            _ = try f.allLeaves(v, buf);
            return buf.items.len == start;
        },
        .later => unreachable, // read through `capVal` only
    }
    const start: u32 = @intCast(buf.items.len);
    _ = try f.allLeaves(v, buf);
    if (buf.items.len != start) try runs.append(f.gpa, .{ start, @intCast(buf.items.len) });
    return true;
}

/// What the expansion of a result entry's sources found beside the atoms
/// (`expandSrcs`, `answerOfParam`).
const SrcState = struct {
    /// One cell can be twice here: the atoms show it (two sources, or two
    /// parts of one, hold one cell), the callee's contract says `twice`, or
    /// an answer can be one cell in two runs (a captured cell; a cell the
    /// holder hands to each run, `held`). The location keeps its claim; its
    /// parts are not apart (`REntry.twice`).
    twice: bool = false,
    written: bool = false,
    inst: u32 = none,
    /// The labels of the caller's result entry below the callee's result entry in work.
    suffix: []const u64 = &.{},
    /// The answers in work: `(holder, location, result entry of the function there)`.
    /// An answer that comes back to itself adds no cell (the least fixed point).
    seen: [24][3]u32 = undefined,
    nseen: u32 = 0,
    /// Each part of the answer is asked for, not the one at `suffix`.
    whole: bool = false,
    /// Neither the callee nor a function argument casts (`Contract.casts`,
    /// `argsCast`): it answers a value only at a location of the value's own
    /// type, so an argument of a type of no location is at no location the
    /// reading has (kernel §3.4, *A value of no location in a typed answer*).
    typed: bool = false,
    /// The answer can hold a cell that the holder handed on: a cell of the
    /// call's arguments or of what it read through them (`resolve`), or one
    /// of a lost or the frame's own answer. An answer that holds none holds
    /// only cells the function made in its run, captured cells (`twice`) and
    /// cells outside the frame (`apply`).
    handed: bool = false,
    fn visit(st: *SrcState, use: *const Use, k: u32) enum { new, old, full } {
        for (st.seen[0..st.nseen]) |x| if (x[0] == use.id and x[1] == use.j and x[2] == k) return .old;
        if (st.nseen == st.seen.len) return .full;
        st.seen[st.nseen] = .{ use.id, use.j, k };
        st.nseen += 1;
        return .new;
    }
};

/// The callee writes the cells `f.atoms[from..]`, or hands them to a
/// function that can, and answers them: their names here are old from this
/// call on (`Atom.dead`).
fn oldNames(f: *Frame, from: usize, st: *SrcState) void {
    const at = f.timeOf(st.inst);
    for (f.atoms.items[from..]) |*a| a.dead = at;
    st.written = true;
}

/// Append to `f.atoms` what the sources `srcs` of the callee's result entry
/// `cr` are for the caller's result entry `e`.
fn expandSrcs(f: *Frame, base: *const Use, srcs: []const Src, rsig: u32, cr: u32, rlayout: u32, e: u32, st: *SrcState) Error!void {
    if (f.tick()) return;
    const c = base.c;
    const args = base.args;
    const first = f.atoms.items.len;
    var suffix: std.ArrayList(u64) = .empty;
    defer suffix.deinit(f.gpa);
    const rloc = f.m.loc.layoutEntries(rlayout)[e].loc;
    const cloc = f.m.loc.layoutEntries(rsig)[cr].loc;
    if (f.m.loc.isPrefix(cloc, rloc)) try f.suffixOf(rloc, cloc, &suffix);
    st.suffix = suffix.items;
    defer st.suffix = &.{};
    // Each source is a part of the run, and the one duplicate test is
    // between parts (`dupOverlap`, below). Two locations of one argument are
    // two sets of cells, though one atom of the caller can name both (the
    // entry level and the deep level of a part of a recursive value): the
    // sources of one parameter are one part, unless the fallback cover gave
    // one of them each location (`hit_all`).
    const Part = struct { start: u32, end: u32, src: Src };
    var parts: std.ArrayList(Part) = .empty;
    defer parts.deinit(f.gpa);
    var group_param: u32 = none;
    for (srcs) |s| {
        const before: u32 = @intCast(f.atoms.items.len);
        f.hit_all = false;
        switch (s.kind) {
            // A cell the callee made: one root for its name at this call (kernel §4.2).
            .fresh => try f.freshAtom(base.key, base.holder, f.m.isDraft(c), s.a, s.e != 0, st.inst, &f.atoms),
            .outside => try f.atoms.append(f.gpa, outside_atom),
            .param => {
                // A parameter the call did not hand (a contract of another
                // arity): nothing is known of it, so each argument.
                if (s.a >= args.len) {
                    try f.lostAnswer(base, st);
                } else {
                    const ai = if (s.a < base.site.arg_insts.len) base.site.arg_insts[s.a].int() else none;
                    // An argument of a type of no location holds `outside`
                    // (§3.4); a callee that does not cast answers it only at
                    // a location of its type, which no reading has, so it is
                    // not at entry `e` (kernel §3.4, *A value of no location
                    // in a typed answer*).
                    if (st.typed and args[s.a] == v_outside and ai != none and try f.layoutLen(try f.m.placeOfInst(ai)) == 0) continue;
                    if (try f.pairedLeaves(args[s.a], ai, c.layouts[s.a], s.e, rsig, cr, rlayout, e)) st.twice = true;
                    if (c.flags[c.off[s.a] + s.e] & (flag_w | flag_s) != 0) f.oldNames(before, st);
                    // At positions of the argument's list (kernel §6 rule 10, *A position*).
                    if (s.p != 0) try f.atPositions(base, s, before);
                }
            },
            .twice => st.twice = true,
            .answer => {
                // The answer of a function parameter, read off the function
                // that flowed there; its cells are atoms as any other's.
                try f.answerOfParam(base, s, st.suffix, st, 0);
            },
        }
        const end: u32 = @intCast(f.atoms.items.len);
        if (end == before) continue;
        if (s.kind == .param and s.a == group_param and !f.hit_all and parts.items.len != 0) {
            parts.items[parts.items.len - 1].end = end;
        } else try parts.append(f.gpa, .{ .start = before, .end = end, .src = s });
        group_param = if (s.kind == .param and !f.hit_all) s.a else none;
    }
    _ = first;
    // One cell in two parts of one location is one cell at two places,
    // unless the two parts are alternatives (`alternatives`). Only a part
    // that is an answer has an alternative: the other parts of a large run
    // are tested together by `runsShare`, linear in their atoms, and each
    // pair with an answer as before. A location that holds one cell twice
    // already needs no test.
    if (st.twice) return;
    var total: usize = 0;
    for (parts.items) |x| total += x.end - x.start;
    if (total > share_small) {
        var runs: std.ArrayList([2]u32) = .empty;
        defer runs.deinit(f.gpa);
        for (parts.items) |x| if (x.src.kind != .answer) try runs.append(f.gpa, .{ x.start, x.end });
        if (try f.runsShare(f.atoms.items, runs.items, null)) st.twice = true;
        for (parts.items, 0..) |x, i| for (parts.items[0..i]) |y| {
            if (x.src.kind != .answer and y.src.kind != .answer) continue;
            if (f.charge(1)) {
                st.twice = true;
                break;
            }
            if (alternatives(c, x.src, y.src)) continue;
            if (f.dupOverlap(f.atoms.items[x.start..x.end], f.atoms.items[y.start..y.end])) st.twice = true;
        };
        return;
    }
    for (parts.items, 0..) |x, i| for (parts.items[0..i]) |y| {
        // Each pair is work of its own (kernel §8); past the budget the two
        // parts share a cell.
        if (f.charge(1)) {
            st.twice = true;
            break;
        }
        if (alternatives(c, x.src, y.src)) continue;
        if (f.dupOverlap(f.atoms.items[x.start..x.end], f.atoms.items[y.start..y.end])) st.twice = true;
    };
}

/// The atoms `f.atoms[from..]` of a source at positions of its argument's
/// list (`Src.p`, kernel §6 rule 10, *A position*): each is read at that
/// position of the match of the argument and the index argument (`posKey`).
/// Where the two name no match, the atoms keep what they were read at.
fn atPositions(f: *Frame, base: *const Use, s: Src, from: usize) Error!void {
    const q = (s.p - 1) / 2;
    const k: u32 = (s.p - 1) % 2;
    if (s.a >= base.args.len or q >= base.args.len or q >= base.site.arg_insts.len) return;
    const match = try f.posKey(base.args[s.a], base.site.arg_insts[q].int());
    if (match == none) return;
    _ = f.charge(f.atoms.items.len - from);
    for (f.atoms.items[from..]) |*a| if (a.root != 0) {
        a.pos = match << pos_bits | k;
    };
}

/// Whether two sources of one summary location of a callee's result are
/// alternatives: each cell is at one of them, so the same atom in both is
/// not one cell at two places. That is the case for the answer of a
/// function `g` and a parameter location the callee hands `g` `free`: a cell
/// handed `free` is read by the callee no more, so it is in the answer or it
/// stays, never both (a `taken` row of `core/`, or a callee whose own frame
/// showed no later read of it: the supply's demand). Any other pair is
/// tested as atoms.
fn alternatives(c: *const Contract, x: Src, y: Src) bool {
    if (x.kind == .answer and y.kind == .param) return handsFree(c.fns[x.a], y);
    if (y.kind == .answer and x.kind == .param) return handsFree(c.fns[y.a], x);
    return false;
}

/// Whether the function contract `fnc` hands the function the parameter location `par`, `free`.
fn handsFree(fnc: ?*const CMod.Fn, par: Src) bool {
    const g = fnc orelse return false;
    for (g.supply, g.free) |srcs, free| if (free) for (srcs) |x| if (x.kind == .param and x.a == par.a and x.e == par.e) return true;
    return false;
}
/// The atoms of argument `v` at the callee's parameter entry `pe`, for the
/// caller's result entry `e`: when both are below a type variable, the part
/// of the argument at the same place below it.
fn pairedLeaves(f: *Frame, v: Val, arg_inst: u32, psig: u32, pe: u32, rsig: u32, cr: u32, rlayout: u32, e: u32) Error!bool {
    const start = f.atoms.items.len;
    const dup = try f.pairedLeavesAt(v, psig, pe, rsig, cr, rlayout, e);
    // A record's slots are no cell of another kind: a caller's list there
    // that only slots feed is fed by no cell (a record answered at a type
    // variable and read as a record of lists, `un : { a : Int } → b`).
    const no_cell = for (f.atoms.items[start..]) |a| {
        if (!f.isSlotAtom(a)) break false;
    } else true;
    // Only a list of the caller's is asked: a wide location of the caller
    // (a `Js.Value`, a type variable) holds the whole of what the callee
    // answers, of which an `Int` at the callee's `a` is no part.
    if (no_cell and arg_inst != none and f.m.loc.layoutEntries(rlayout)[e].kind == .list) {
        // No cell of the argument at the location: proved empty where the
        // argument's type has a cell there (another constructor's argument),
        // but where its type has none (`Int` at the callee's `a`) and the
        // caller reads a cell (a list at the callee's `b`), the callee cast
        // what it was handed (`un : W a → W b`, `un r = Js.to (Js.from r)`):
        // a cell no rule names, `outside` (research report 148).
        const m = f.m;
        const rentry = m.loc.layoutEntries(rsig)[cr];
        const rloc = m.loc.layoutEntries(rlayout)[e].loc;
        var labels: std.ArrayList(u64) = .empty;
        defer labels.deinit(f.gpa);
        // A slot of the parameter stands for its record's object: the path is the record's.
        const pentry = m.loc.layoutEntries(psig)[pe];
        try m.loc.labels(if (pentry.kind == .field) m.loc.loc_parent.items[pentry.loc] else pentry.loc, &labels, f.gpa);
        if (m.loc.isPrefix(rentry.loc, rloc)) {
            var below: std.ArrayList(u64) = .empty;
            defer below.deinit(f.gpa);
            try m.loc.labels(rloc, &below, f.gpa);
            try labels.appendSlice(f.gpa, below.items[m.loc.loc_depth.items[rentry.loc]..]);
        }
        _ = f.charge(Loc.scanUnits(labels.items.len));
        if (m.loc.emptyAlongLabels(try m.placeOfInst(arg_inst), labels.items, true)) try f.atoms.append(f.gpa, outside_atom);
    }
    return dup;
}

/// `argLeaves(v, psig, pe)` whole, into `f.atoms`. In the result of one call
/// (`paired_gen`), each source is read for each location of the caller's
/// reading that holds it, and with no suffix the atoms are the same each
/// time: they are kept for the call, with the duplicate and `hit_all` the
/// read found, and a second read copies them, one unit for each atom
/// (kernel §8; research report 159).
fn argLeavesKept(f: *Frame, v: Val, psig: u32, pe: u32) Error!bool {
    if (f.paired_gen == 0) return f.argLeaves(v, psig, pe, &.{}, false, &f.atoms);
    const key: [4]u32 = .{ f.paired_gen, v, psig, pe };
    if (f.paired_memo.get(key)) |hit| {
        _ = f.charge(1 + hit.len);
        try f.atoms.appendSlice(f.gpa, f.paired_buf.items[hit.start..][0..hit.len]);
        if (hit.hit_all) f.hit_all = true;
        return hit.dup;
    }
    const start = f.atoms.items.len;
    const outer_all = f.hit_all;
    f.hit_all = false;
    const dup = try f.argLeaves(v, psig, pe, &.{}, false, &f.atoms);
    const got_all = f.hit_all;
    f.hit_all = outer_all or got_all;
    if (!f.m.steps_over) {
        const at: u32 = @intCast(f.paired_buf.items.len);
        try f.paired_buf.appendSlice(f.gpa, f.atoms.items[start..]);
        try f.paired_memo.put(f.gpa, key, .{ .start = at, .len = @intCast(f.atoms.items.len - start), .dup = dup, .hit_all = got_all });
    }
    return dup;
}

fn pairedLeavesAt(f: *Frame, v: Val, psig: u32, pe: u32, rsig: u32, cr: u32, rlayout: u32, e: u32) Error!bool {
    const m = f.m;
    const pentry = m.loc.layoutEntries(psig)[pe];
    const rentry = m.loc.layoutEntries(rsig)[cr];
    if (!(pentry.kind.wide() and rentry.kind.wide())) {
        const dup = try f.argLeavesKept(v, psig, pe);
        // A wide location of one side and a concrete one of the other: the
        // callee casts what it was handed (`Js.to` of a parameter of a type
        // variable answered as a record, a tuple answered as a type
        // variable). A record's slot of the caller's answer there holds an
        // object of the argument's only where the argument has a slot of
        // that field (or a wide entry, which holds every object); else no
        // cell names it (kernel §3.4, research report 147).
        if (pentry.kind.wide() != rentry.kind.wide() and try f.castSlotLost(v, pentry.loc, rentry, m.loc.layoutEntries(rlayout)[e].loc)) try f.atoms.append(f.gpa, outside_atom);
        return dup;
    }
    const rloc = m.loc.layoutEntries(rlayout)[e].loc;
    // The fallback cover: the caller's entry is not below the callee's.
    if (!m.loc.isPrefix(rentry.loc, rloc)) return f.argLeaves(v, psig, pe, &.{}, false, &f.atoms);
    var labels: std.ArrayList(u64) = .empty;
    defer labels.deinit(f.gpa);
    try m.loc.labels(rloc, &labels, f.gpa);
    const skip = m.loc.loc_depth.items[rentry.loc];
    // A wide entry of the caller's own type stands for each cell below that place.
    f.suffix_fallback = false;
    const dup = try f.argLeaves(v, psig, pe, labels.items[skip..], m.loc.layoutEntries(rlayout)[e].kind.wide(), &f.atoms);
    // The argument has no location at that part (a value that a conversion
    // gave another type): every cell it has is read there, and a summary
    // location of the caller is then no single place (kernel §3.4).
    return dup or (f.suffix_fallback and !m.loc.layoutEntries(rlayout)[e].single);
}

// ---- function values: one rule (research report 112 §2) -------------------------------------
//
// A function value is in one of two states. **Known**: the frame has its
// code and what it captured (a `closure` or `fnref` value), or it is the
// frame's own function parameter, whose contract the frame writes. **Default**:
// it is in a location that no contract describes (an item of a value, a
// result, the answer of a call). A function in a default location asks
// nothing of its caller, and its holder can do anything with it.
//
// Each consumer of a known function is a **use** (`Use`), and `flow` judges
// the function against it. A consumer that no contract describes is the
// `top` use. So a known function goes to the default state only through
// `flow`, and a fact that the checker does not have is never "nothing
// happens": it is the `top` use, which refuses a function that asks for
// something.

/// The frame's own function parameter that `v` is, or `none`.
fn ownFnRoot(f: *Frame, v: Val) u32 {
    const n = f.nodes.items[v];
    if (n.tag != .ref) return none;
    const r = f.roots.items[n.a];
    return if ((r.kind == .param or r.kind == .capture) and n.b == r.path) n.a else none;
}

/// Whether `root` is a parameter or a capture of a function type: its one location is the function.
fn isFnRoot(f: *const Frame, root: u32) bool {
    if (root == none) return false;
    const r = f.roots.items[root];
    if (r.kind != .param and r.kind != .capture) return false;
    const es = f.m.loc.layoutEntries(r.layout);
    if (es.len == 1 and es[0].kind == .closure and es[0].loc == 0) return true;
    // A type past a limit of the place graph has the layout of a type variable.
    return r.index < f.param_ty.items.len and f.m.fnType(f.param_ty.items[r.index]) != null;
}

/// Whether entry `ea` of layout `la` and entry `eb` of layout `lb`, two
/// readings of one type position, can name one cell. The call map
/// (`Loc.cover`) maps an entry of one layout to the entry of the other that
/// covers it: the same location, a wide one above it, or the row of a record
/// that does not name its field. An answer of the map holds every cell of the
/// mapped entry when that entry is no wider than it (a type variable mapped
/// to a list at its own location is wider: it is the list and its elements).
/// Such an answer decides, since the entries of one layout name apart cells;
/// where neither direction decides, the pair is one cell (kernel §4.1: the
/// pessimistic side). Every comparison of two layouts' locations goes
/// through this, never through their label paths.
fn locsMeet(f: *Frame, la: u32, ea: u32, lb: u32, eb: u32) Error!bool {
    const m = f.m;
    const las = m.loc.layoutEntries(la);
    const lbs = m.loc.layoutEntries(lb);
    const ab = (try m.loc.cover(la, lb))[eb];
    const ba = (try m.loc.cover(lb, la))[ea];
    const ab_decides = ab < Loc.all and (!lbs[eb].kind.wide() or las[ab].kind.wide());
    const ba_decides = ba < Loc.all and (!las[ea].kind.wide() or lbs[ba].kind.wide());
    if (ab_decides and ab == ea) return true;
    if (ba_decides and ba == eb) return true;
    return !(ab_decides or ba_decides);
}

/// `locsMeet` of one pair of layouts `la`, `lb`, read the other way: for an
/// entry of `la`, every entry of `lb` that it meets. `locsMeet(ea, eb)` holds
/// when the map from `lb` decides `eb` and names `ea`, or the map from `la`
/// decides `ea` and names `eb`, or neither decides. So the entries of `lb`
/// that `ea` meets are those whose decided image is `ea` (`inv`), the image
/// of `ea` when it is decided, and, when it is not, every entry of `lb`
/// whose image is not decided (`undecided`).
const MeetIndex = struct {
    /// Per entry of `la`: the entries of `lb` that the map from `lb` decides and maps to it.
    inv_start: []u32,
    inv: []u32,
    /// Per entry of `la`: its decided image in `lb`, or `none`.
    image: []u32,
    /// The entries of `lb` whose image in `la` is not decided.
    undecided: []u32,
};

fn meetIndex(f: *Frame, la: u32, lb: u32) Error!*const MeetIndex {
    if (f.meet_index.get(.{ la, lb })) |x| return x;
    const m = f.m;
    const las = m.loc.layoutEntries(la);
    const lbs = m.loc.layoutEntries(lb);
    const ab = try m.loc.cover(la, lb);
    const ba = try m.loc.cover(lb, la);
    const x = try f.gpa.create(MeetIndex);
    x.inv_start = try f.gpa.alloc(u32, las.len + 1);
    @memset(x.inv_start, 0);
    var undecided: std.ArrayList(u32) = .empty;
    for (lbs, 0..) |eb_e, eb| {
        const a = ab[eb];
        if (a < Loc.all and (!eb_e.kind.wide() or las[a].kind.wide())) x.inv_start[a + 1] += 1 else try undecided.append(f.gpa, @intCast(eb));
    }
    for (1..las.len + 1) |i| x.inv_start[i] += x.inv_start[i - 1];
    x.inv = try f.gpa.alloc(u32, x.inv_start[las.len]);
    const fill = try f.gpa.alloc(u32, las.len);
    defer f.gpa.free(fill);
    @memcpy(fill, x.inv_start[0..las.len]);
    for (lbs, 0..) |eb_e, eb| {
        const a = ab[eb];
        if (a < Loc.all and (!eb_e.kind.wide() or las[a].kind.wide())) {
            x.inv[fill[a]] = @intCast(eb);
            fill[a] += 1;
        }
    }
    x.image = try f.gpa.alloc(u32, las.len);
    for (las, 0..) |ea_e, ea| {
        const b = ba[ea];
        x.image[ea] = if (b < Loc.all and (!ea_e.kind.wide() or lbs[b].kind.wide())) b else none;
    }
    // The index is built once for each pair of layouts in a frame, and
    // costs its two layouts (kernel §8).
    _ = f.charge(2 * (las.len + lbs.len));
    x.undecided = undecided.items;
    try f.meet_index.put(f.gpa, .{ la, lb }, x);
    return x;
}

/// Every entry of layout `lb` that entry `ea` of layout `la` meets
/// (`locsMeet`), each once, in no order. Each entry is a step of the
/// declaration's budget (kernel §8); null past it, which a caller reads as
/// the walk giving up.
fn meetsOf(f: *Frame, la: u32, ea: u32, lb: u32, out: *std.ArrayList(u32)) Error!bool {
    const x = try f.meetIndex(la, lb);
    out.clearRetainingCapacity();
    for (x.inv[x.inv_start[ea]..x.inv_start[ea + 1]]) |eb| {
        if (f.tick()) return false;
        try out.append(f.gpa, eb);
    }
    const img = x.image[ea];
    if (img != none) {
        // The image is listed already when the map from `lb` names `ea` too.
        if (std.mem.indexOfScalar(u32, out.items, img) == null) try out.append(f.gpa, img);
    } else for (x.undecided) |eb| {
        if (f.tick()) return false;
        try out.append(f.gpa, eb);
    }
    if (safety and smallLayout(f, lb)) {
        // The index says what `locsMeet` says, pair for pair.
        for (0..f.m.loc.layoutEntries(lb).len) |eb| {
            const in_out = std.mem.indexOfScalar(u32, out.items, @intCast(eb)) != null;
            std.debug.assert(in_out == try f.locsMeet(la, ea, lb, @intCast(eb)));
        }
    }
    return true;
}

fn smallLayout(f: *Frame, l: u32) bool {
    return f.m.loc.layoutEntries(l).len <= 64;
}

/// Whether the answer `v` of an identity (the argument at `arg_inst`, or
/// `none`) is read at `place`, another type of parts than its own, with a
/// location that no location of the value's own layout covers. Both are
/// types of parts (neither is a type variable or an opaque type, whose wide
/// entries §3.4 reads), so the identity is a cast between two shapes of one
/// JavaScript object (a tuple read as a record, a constructor as another
/// type's constructor, a list of tuples as a list of records): the value's
/// own steps say nothing of the reading's, which can name a part of
/// another constructor than the one the value was built with, or a record's
/// slot that no cell names, at any depth (research report 147). The map is
/// kept for each pair; its scan is work (kernel §8).
fn punned(f: *Frame, v: Val, arg_inst: u32, place: PlaceId) Error!bool {
    const m = f.m;
    // A value of no cell (a number, a parameter of a type of no location)
    // read at a type with a location: whatever is there, the value's own
    // reading names none of it, though the argument's type is a type
    // variable or `Js.Value` (`fromInt n = Js.to (Js.from n)`: the `Value`
    // of `n` holds nothing the walk can name, and the list read out of it
    // was a cell). A cast through a type of no cell let its cells escape
    // (`narrowed`), so it is `unknown`, never a new list (research report 148).
    // A type variable or an opaque type is no exemption here: the reading's
    // wide entry names whatever a caller reads there (`unhide : Int → b`,
    // `unhide t = Js.to (Js.from t)`, read as a list), and a value of no
    // cell has no wide entry that holds it.
    if (v == v_none) return try f.layoutLen(place) != 0;
    const own = f.placeOfVal(v) orelse (if (arg_inst != none) try m.placeOfInst(arg_inst) else return false);
    if (own == place) return false;
    // A type variable or an opaque type is a wide entry, which §3.4 reads
    // (`Loc.holes`). A type of no cell (`Int`, a crossing foreign type) is
    // no wide entry: it has no location at all, so a reading of it at a
    // type with a list or a record names cells it does not (research report
    // 148).
    for ([_]PlaceId{ own, place }) |p| switch (m.places.kind(p)) {
        .@"var", .@"opaque" => return false,
        .record, .tuple, .ctor, .list, .dict, .ref, .closure, .cross => {},
    };
    // Each location of the reading that a location of the value's own
    // layout covers (the same one, or a wide one above it) is one the value
    // has: an array read as another type of array (`List a` as `Builder a`)
    // is no pun. A location that none covers is a part the value does not
    // have, or has as another constructor's (kernel §3.4), whatever its kind:
    // a record's slot that no cell names, a part of the constructor the
    // value was not built with, an array where the value has a number (an
    // `Int`, or a list of numbers read as a list of lists). The map answers
    // `none` for such a location where the value's own layout is empty, and
    // `Loc.all` (covered by every entry) where it is not; the readers of the
    // answer go through the map the other way (`argEntries`, `leavesSet`),
    // where no entry of the value's own layout is at it, and found nothing.
    // Before, a list's level that none covers was taken to be read through a
    // root's missing step (`project`), which only a pattern takes (research
    // report 148). A type of no cell has no location to read.
    const view = try m.loc.layoutOf(place);
    const cov = try m.loc.cover(try m.loc.layoutOf(own), view);
    _ = f.charge(Loc.scanUnits(cov.len));
    for (cov) |c| if (c == none or c == Loc.all) return true;
    return false;
}

/// The answer `v` of an identity read at `place`, a type with fewer places
/// than the value's own: each location of the value's own layout that no
/// location of the reading covers (`cover(view, own)` is `none` or
/// `Loc.all`), and each wide one where the reading has a part of no location
/// below it, holds cells that no reader of the answer can name. The
/// answer is the same JavaScript value, and a later cast can read it at the
/// first type again (`hide : List Int → Int`, then `Js.to` back to a list):
/// so those cells escape at the call (kernel §3.4, *A value read at a type
/// with fewer places than its own*; research report 148). A type variable or
/// an opaque type of the reading is a wide entry, which covers every cell
/// below it. The scan of the map is work (kernel §8).
fn narrowed(f: *Frame, v: Val, inst: u32, place: PlaceId, arg_inst: u32) Error!void {
    return f.narrowedAs(v, inst, place, f.m.typeOfInst(inst).unwrap(), if (arg_inst != none) f.m.typeOfInst(arg_inst).unwrap() else null);
}

/// `narrowed`, where the reading's type is `rty` (`null`: not known).
///
/// The place graph has one place for every type variable, so a value of
/// one type variable read at another (`Js.to (Js.from v)` with `v : a`
/// answered at `b`, `fm : Maybe a → b`) is one place read at itself: the
/// types tell them apart (`varAtVar`). Before research report 151 no rule
/// did, so the frame did not cast, and a caller that filled `a` with a pair
/// and `b` with `List Int × Int` read the second list as an `Int`.
fn narrowedAs(f: *Frame, v: Val, inst: u32, place: PlaceId, rty: ?Var, arg_ty: ?Var) Error!void {
    const m = f.m;
    const own = f.placeOfVal(v) orelse return;
    if (own == place) {
        // One place, and a type variable in it (`b`, `List b`): two types
        // where the variables are two.
        const es = m.loc.layoutEntries(try m.loc.layoutOf(place));
        _ = f.charge(Loc.scanUnits(es.len));
        for (es) |e| if (e.kind == .@"var") {
            f.varAtVar(v, rty, arg_ty);
            break;
        };
        return;
    }
    switch (m.places.kind(place)) {
        // A value read at a type variable of another type than its own: the
        // variable is a wide entry here, which holds every cell, but a caller
        // fills it in, and where it fills it with a type that has a part of
        // no location the value's cells can be there. The contract says so
        // (`Contract.casts`), and each caller reads it (`applyAt`,
        // `escapeHidden`; research report 150).
        // A `Js.Value` read at a type variable is what it was made from. A
        // value of the frame read through an identity (`Js.from x`) is that
        // value, not a `Js.Value`, and is read above. A `Js.Value` the
        // caller handed (a parameter, a capture, a part of one) is the
        // caller's value, which the caller reads as it made it where it
        // reads the answer (`escapeWide`, `narrowed`); no mark: `core/`
        // reads the values it keeps in JavaScript arrays back so, and a
        // mark made every function of `core/List` cast (research report
        // 150). A `Js.Value` the frame made of parts (`Js.array [ Js.from x
        // ]`, `Js.object`, the answer of a call, of unknown code) holds them
        // below its place, at a depth no type names: what it holds escapes
        // here (`madeOfParts`; research report 151). The answer of unknown
        // code escaped already, so this costs nothing there.
        .@"var" => {
            try f.readAtVar(v, inst);
            return;
        },
        .@"opaque" => return,
        .record, .tuple, .ctor, .list, .dict, .ref, .closure, .cross => {},
    }
    const own_layout = try m.loc.layoutOf(own);
    const own_es = m.loc.layoutEntries(own_layout);
    if (own_es.len == 0) return;
    const view = try m.loc.layoutOf(place);
    const view_es = m.loc.layoutEntries(view);
    // One layout, location for location: one type read at itself.
    if (own_layout == view) return;
    if (own_es.len == view_es.len) {
        _ = f.charge(Loc.scanUnits(own_es.len));
        for (own_es, view_es) |a, b| {
            if (a.loc != b.loc or a.kind != b.kind) break;
        } else return;
    }
    const cov = try m.loc.cover(view, own_layout);
    if (f.charge(Loc.scanUnits(cov.len))) {
        try f.escape(v, inst);
        return;
    }
    // A type variable inside the reading (`List b`, `b × Int`) is filled in
    // by a caller, as one at its root is (the `.var` case above): a location
    // of the value's own layout at or below it that is not a type variable
    // at its place is a value of another type read there, a cast; a
    // `Js.Value` the frame made of parts holds them below its place, which
    // the reading's variable can be, so they escape (research report 151).
    var made: ?bool = null;
    for (cov, 0..) |c, k| {
        if (c == none or c == Loc.all) continue;
        const ok = own_es[k].kind;
        if (ok == .@"opaque") {
            // Its parts are below its place: any variable of the reading
            // at or below the place the map gives it.
            const at = view_es[c].loc;
            const under_var = for (view_es) |ve| {
                if (ve.kind == .@"var" and m.loc.isPrefix(at, ve.loc)) break true;
            } else false;
            _ = f.charge(Loc.scanUnits(view_es.len));
            if (!under_var) continue;
            if (made == null) made = try f.madeOfParts(v, 0);
            if (made.?) {
                try f.escape(v, inst);
                if (std.debug.runtime_safety) try f.checkMadeEscaped(v);
                break;
            }
            continue;
        }
        if (view_es[c].kind != .@"var") continue;
        if (ok == .@"var" and own_es[k].loc == view_es[c].loc) continue;
        f.casts = true;
    }
    // A location of the value's own layout that no location of the reading
    // is at, nor a wide one above (`none`, or `Loc.all` where the reading has
    // locations elsewhere), is at a part of the reading of no location, or at
    // none: its cells escape. And a wide location of the value's own layout
    // (a `Js.Value`, a type variable) holds cells at places no layout names:
    // where the reading has a part of no location below it, they can be
    // there (`Loc.holeAt`). Before research report 150 a location at
    // `Loc.all` was held "at every entry of the reading", but a part of the
    // reading at a type of no location is `outside`, so the cells a reader
    // took out there were nobody's.
    for (cov, 0..) |c, k| {
        const hidden = c == none or c == Loc.all or
            (own_es[k].kind.wide() and !view_es[c].kind.wide() and try m.loc.holeAt(place, own_es[k].loc));
        if (!hidden) continue;
        const start: u32 = @intCast(f.atoms.items.len);
        _ = try f.leaves(v, @intCast(k), &f.atoms);
        try f.noteEscape(start, inst);
    }
}

/// Whether every answer of the frame is its parameter 0 itself, whole: a
/// reference to its root (an identity passes the value on as it is), or a
/// join of such arms (`Contract.exact`).
fn answersParam0(f: *Frame) bool {
    if (f.own_params != 1 or f.params.items.len != 1 or f.failed) return false;
    const r0 = f.params.items[0];
    if (f.returns.items.len == 0) return false;
    for (f.returns.items) |v| if (!f.isRootOf(v, r0, 0)) return false;
    return true;
}

fn isRootOf(f: *Frame, v: Val, root: u32, depth: u32) bool {
    if (depth > 8 or v == v_unbound) return false;
    const n = f.nodes.items[v];
    return switch (n.tag) {
        .ref => n.a == root and n.b == f.roots.items[root].path,
        .join => blk: {
            for (0..n.b) |ki| if (!f.isRootOf(f.lists.items[n.a + 2 * ki], root, depth + 1)) break :blk false;
            break :blk true;
        },
        .none, .outside, .built, .closure, .fnref, .unknown => false,
        .later => unreachable, // read through `capVal` only
    };
}

/// Whether a call of `code` answers its one argument as it is: its contract
/// is an identity's (`isIdentity`) and does not cast, or the build writes the
/// call as its argument (`Mod.emitsArgument`: `Js.from`, `Js.to`). A
/// contract that casts places its parameter at or below its answer, at a
/// depth no word names (research report 151).
fn identityCall(f: *Frame, code: Code) bool {
    if (!f.isIdentity(code.contract)) return false;
    if (!code.contract.casts) return true;
    // A walked body that answers its parameter itself: the cast it read the
    // value at is the caller's reading of the same value (`narrowed`).
    if (code.contract.exact) return true;
    return code.inst == none and code.decl[0] != none and f.m.emitsArgument(code.decl);
}

/// Whether the contract is that of a function that answers its one parameter
/// as it is and does nothing else with it.
fn isIdentity(f: *const Frame, c: *const Contract) bool {
    const m = f.m;
    // A contract that holds one cell of the parameter at two places of the
    // answer (`Js.to (Js.from ( x, x ))`) answers no value as it is.
    if (c.nonlinear) return false;
    if (c.arity != 1 or c.res.len != 1 or c.res[0].len != 1 or c.flags.len != 1 or c.flags[0] & (flag_w | flag_e) != 0) return false;
    if (c.fns[0]) |fnc| {
        // A function parameter that the body answers and does not call.
        if (fnc.called or fnc.ans_escapes or fnc.rewrites) return false;
        for (fnc.supply) |s| if (s.len != 0) return false;
    }
    const s = c.res[0][0];
    const pe = m.loc.layoutEntries(c.layouts[0])[0];
    const re = m.loc.layoutEntries(c.layouts[1])[0];
    return s.kind == .param and s.a == 0 and s.e == 0 and pe.loc == 0 and re.loc == 0 and pe.kind.wide() and re.kind.wide();
}

fn codeOf(f: *Frame, v: Val) Error!?Code {
    const n = f.nodes.items[v];
    return switch (n.tag) {
        .closure => f.codes.items[n.a],
        .fnref => blk: {
            const c = (try f.m.declContract(.{ n.a, n.b })) orelse break :blk null;
            break :blk .{ .contract = c, .decl = .{ n.a, n.b }, .own_params = c.arity };
        },
        .none, .outside, .ref, .built, .join, .unknown => null,
        .later => unreachable, // read through `capVal` only
    };
}

/// The labels of `loc` below the location `above`, which is `loc` or above it.
fn suffixOf(f: *Frame, loc: u32, above: u32, out: *std.ArrayList(u64)) Error!void {
    const m = f.m;
    out.clearRetainingCapacity();
    try m.loc.labels(loc, out, f.gpa);
    const skip = m.loc.loc_depth.items[above];
    if (skip > out.items.len) {
        out.clearRetainingCapacity();
        return;
    }
    std.mem.copyForwards(u64, out.items[0 .. out.items.len - skip], out.items[skip..]);
    out.shrinkRetainingCapacity(out.items.len - skip);
}

fn refuse(f: *Frame, use: *const Use, cause: Facts.Cause, detail: []const u8) Error!void {
    try f.m.addRefusal(f, use.site.inst, cause, detail);
}

/// The function value `v` is in a location whose holder does `use`: the one
/// rule for function values. It has one case for each thing that `v` can be,
/// and none for where the location is.
fn flow(f: *Frame, v: Val, use: *const Use) Error!void {
    if (v == v_none) return;
    if (f.tick()) return;
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        // One of several values: each of them is in the location.
        for (0..n.b) |ki| try f.flow(f.lists.items[n.a + 2 * ki], use);
        return;
    }
    // Each judgment once (kernel §8): a function judged at a use equal in
    // all that the judgment read is not judged again in this walk.
    // The values are compared, not only their hash: a judgment is never
    // skipped for another's.
    const key = f.flowKey(v, use);
    if (f.flow_memo.get(key)) |run| if (std.mem.eql(Val, f.flow_args.items[run[0]..][0..run[1]], use.args)) return;
    // The same judgment inside itself: a function that its own captures
    // reach. No rule follows it, and the walk gives up (kernel §3.3).
    for (f.flow_active.items) |x| if (std.meta.eql(x.key, key) and std.mem.eql(Val, x.args, use.args)) {
        f.failed = true;
        return;
    };
    try f.flow_active.append(f.gpa, .{ .key = key, .args = use.args });
    const outer = f.ctx_floor;
    f.ctx_floor = std.math.maxInt(u32);
    try f.judge(v, use);
    const floor = f.ctx_floor;
    f.ctx_floor = @min(outer, floor);
    _ = f.flow_active.pop();
    // It read nothing above its use: each use equal to this one gets the same judgment.
    if (floor > use.depth) {
        const at: u32 = @intCast(f.flow_args.items.len);
        try f.flow_args.appendSlice(f.gpa, use.args);
        try f.flow_memo.put(f.gpa, key, .{ at, @intCast(use.args.len) });
    }
    if (f.flow_active.items.len == 0) {
        f.flow_memo.clearRetainingCapacity();
        f.flow_args.clearRetainingCapacity();
    }
}

fn judge(f: *Frame, v: Val, use: *const Use) Error!void {
    // The holder lets the function's answer escape: each cell that the answer can hold escapes here.
    if (use.kind != .top and use.fnc.ans_escapes) try f.escapeAnswer(v, use);
    if (try f.codeOf(v)) |code| return f.flowCode(v, code, use);
    const root = f.ownFnRoot(v);
    if (f.isFnRoot(root)) return f.flowOwn(root, use);
    return f.flowUnknown(v, use);
}

/// Whether a callee loses the function at `use`: no contract describes what
/// it does with it after (`Fn.lost`).
fn lostAt(use: *const Use) bool {
    return use.kind != .top and use.fnc.lost;
}

/// What one judgment of `flow` reads of its use, besides what is above it
/// (`ctx_floor`): the function, the holder's contract and capture, the
/// values, and whether the use above is the default or rewrites.
const FlowKey = struct {
    v: Val,
    kind: u8,
    j: u32,
    own: u32,
    up_top: bool,
    up_rewrites: bool,
    c: usize,
    fnc: usize,
    holder: u64,
    args: u64,
};

fn flowKey(f: *const Frame, v: Val, use: *const Use) FlowKey {
    _ = f;
    const known = use.kind != .top;
    return .{
        .v = v,
        .kind = @backingInt(use.kind),
        .j = use.j,
        .own = use.own,
        .up_top = if (use.up) |u| u.kind == .top else false,
        .up_rewrites = use.up_rewrites,
        .c = if (known) @intFromPtr(use.c) else 0,
        .fnc = if (known) @intFromPtr(use.fnc) else 0,
        .holder = use.holder,
        .args = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(use.args)),
    };
}

/// The use above `u`. A judgment that reads it, when it is not the default,
/// reads what is above its own use (`ctx_floor`).
fn upOf(f: *Frame, u: *const Use) ?*const Use {
    const up = u.up orelse return null;
    if (up.kind != .top) f.ctx_floor = @min(f.ctx_floor, u.depth);
    return up;
}

/// Whether a holder on the way writes a cell after it handed that cell on.
fn rewritesOf(f: *const Frame, use: *const Use) bool {
    _ = f;
    return use.kind != .top and (use.fnc.rewrites or use.up_rewrites);
}

/// A known function meets a use: what it does with each parameter is judged
/// against what the use hands there, and each function that it captured
/// flows to the use that the two contracts compose to. A captured value that
/// the function lets escape escapes only where the use can run the function
/// (`called`, lost or `top`): a holder whose contract says that it does not
/// run the function, and does not lose it, never runs it.
fn flowCode(f: *Frame, v: Val, code: Code, use_in: *const Use) Error!void {
    const lc = code.contract;
    var use = use_in.*;
    use.code = code;
    const inst = use.site.inst;
    if (use.kind == .top or lostAt(&use) or code.own_params != use.fnc.arity) {
        // No contract describes the holder: the function must ask nothing
        // (kernel §6.8). It writes no parameter, and the holder hands each of
        // its function parameters a function in the default state, which
        // keeps what it is handed (`defaultParams`).
        if (f.writesOwn(lc, code.own_params)) try f.refuse(&use, .call, "a function that writes its parameter goes where the checker does not follow it");
        // A capture of a cell the frame made, which the function writes or
        // renews only through the cell's rows, is a writer: it runs at the
        // frame's later switch points (kernel §13 item 12).
        const reg = try f.gpa.alloc(bool, code.ncaps);
        defer f.gpa.free(reg);
        for (reg, 0..) |*x, k| x.* = f.cells_any and (f.isWriter(code, k) or try f.registerWriter(v, code, @intCast(k), inst));
        if (try f.writesCapturedBut(code, reg)) try f.refuse(&use, .call, "a function that writes the contents of a cell it captured goes where the checker does not follow it");
        // It runs at times the frame does not see: each handle it captured
        // has another holder (kernel §13 items 8 and 11).
        for (0..code.ncaps) |k| if (!reg[k]) try f.shareVal(try f.capVal(code, k), inst);
        try f.captureEscapes(code, inst);
        if (use.kind != .top) {
            // A callee lost it. It can keep what it hands, and it can run the
            // function at any later time: what the function captured is held from here on.
            try f.escapeSupplies(&use);
            try f.escape(v, inst);
        }
        const top: Use = .{ .kind = .top, .id = f.useId(), .key = use.key, .site = use.site, .depth = use.depth, .code = code };
        try f.defaultParams(code, &top);
        try f.flowRenews(code, &top, false);
        return f.flowCaptures(code, &top);
    }
    if (f.rewritesOf(&use) and f.keepsOwn(lc, code.own_params)) try f.refuse(&use, .supply, "the function keeps a value that the callee changes later");
    if (use.fnc.called) {
        try f.captureEscapes(code, inst);
        // A holder that runs the function hands its function parameters
        // what the holder's frame let go of: a function in the default state.
        try f.defaultParams(code, &use);
    }
    for (0..use.fnc.arity) |k| {
        const n = lc.off[k + 1] - lc.off[k];
        // A function parameter whose answer the function lets escape: what
        // the holder hands there can be in that answer, so it escapes, as
        // where the function lets the parameter itself escape. Before, only
        // the flag of the parameter's location was read, and a callback that
        // kept the answer of the function it was handed (`λq → Ref.set holder
        // (q ⊤)`, `List.map [ λ⊤ → y ]`) let `y` be written in place.
        const ans_esc = if (lc.fns[k]) |lf| lf.ans_escapes else false;
        for (0..n) |le| {
            const fl = lc.flags[lc.off[k] + le] | (if (ans_esc) flag_e else 0);
            if (fl & flag_w != 0) {
                var seen: Seen = .{};
                try f.ownSupply(&use, code, @intCast(k), @intCast(le), &seen);
            }
            if (fl & flag_e != 0) {
                var sink: EscSink = .{ .inst = inst };
                var slots: std.ArrayList(Slot) = .empty;
                defer slots.deinit(f.gpa);
                if (try f.slotsOf(&use, @intCast(k), lc.layouts[k], @intCast(le), null, &slots)) {
                    for (slots.items) |slot| for (slot.srcs) |ss| try f.resolve(&use, ss, &.{}, false, &sink, 0);
                } else for (use.fnc.off[k]..use.fnc.off[k + 1]) |i| {
                    for (use.fnc.supply[i]) |ss| try f.resolve(&use, ss, &.{}, false, &sink, 0);
                }
            }
        }
    }
    try f.escapeUnplacedAnswer(code, &use);
    try f.captureCells(v, code, &use);
    try f.flowRenews(code, &use, true);
    try f.flowCaptures(code, &use);
}

/// The result entries of the known function `code` that no entry of the
/// answer `use` reads it at holds (`answerOfCode` skips them: the holder's
/// answer type is an instance with fewer locations, a function of `a → b`
/// read as `a → Int`): the answer is the same JavaScript value, which a cast
/// reads back, so what those entries hold escapes at the use (kernel §3.4,
/// `narrowed`; research report 150). The scans are work (kernel §8).
fn escapeUnplacedAnswer(f: *Frame, code: Code, use: *const Use) Error!void {
    const m = f.m;
    const lc = code.contract;
    const fl = lc.layouts[lc.arity];
    const ul = use.fnc.layouts[use.fnc.arity];
    const les = m.loc.layoutEntries(fl);
    const ues = m.loc.layoutEntries(ul);
    const n = les.len;
    if (n == 0) return;
    const cov = try m.loc.cover(ul, fl);
    _ = f.charge(Loc.scanUnits(cov.len));
    var psuffix: std.ArrayList(u64) = .empty;
    defer psuffix.deinit(f.gpa);
    for (cov, 0..) |cv, k| {
        if (!namesCell(lc.res[k])) continue;
        // Placed nowhere: no location of the holder's answer holds it.
        const unplaced = cv == none or (cv == Loc.all and !try f.anyMeets(ul, fl, @intCast(k)));
        // A function that casts (`Contract.casts`) answers at a wide
        // location a value of another type than the holder reads there: where
        // the holder reads it at a location that is not wide (a concrete
        // type, which can have a part of no location below it; the holder's
        // layout names no place to ask), what it holds escapes.
        const read_narrow = les[k].kind.wide() and (cv == Loc.all or (cv != none and !ues[cv].kind.wide()));
        const hidden = lc.casts and read_narrow;
        // A wide parameter location answered at this wide location is the
        // argument as it is, which the holder reads at its own type: no
        // cast only where the holder's parameter and answer are one type at
        // the same place (`identity` handed to `Model → Model`); else what it
        // holds escapes, as at a call (`escapeWide`; research report 150).
        const wide_param = read_narrow and for (lc.res[k]) |ls| {
            if (ls.kind != .param or ls.a >= code.own_params) continue;
            const pe = m.loc.layoutEntries(lc.layouts[ls.a])[ls.e];
            if (!pe.kind.wide()) continue;
            // The holder hands and reads one type, at the same place of it:
            // the function answers the value where it was (`identity` handed
            // to `Model → Model`, `List.reverse` to `List Int → List Int`).
            if (pe.loc == les[k].loc and ls.a < use.fnc.arity and use.fnc.layouts[ls.a] == ul) continue;
            break true;
        } else false;
        if (!unplaced and !hidden and !wide_param) continue;
        // Placed nowhere, but only of parameters the holder hands nothing at
        // that place (its parameter type has no location there: `List a →
        // List a` held as `List Int → List Int`, whose elements are numbers):
        // no cell is lost.
        if (unplaced and !hidden and !wide_param and try holderGivesNone(f, code, use, k)) continue;
        var st: SrcState = .{ .inst = use.site.inst, .whole = true };
        const start: u32 = @intCast(f.atoms.items.len);
        try f.answerSrcs(code, use, k, cv, null, &st, 0, &psuffix);
        try f.noteEscape(start, use.site.inst);
    }
}

/// Whether every source of the function's result location `k` names no cell a
/// reader could miss: a parameter location at whose place the holder's
/// parameter type has no location, nor a wide one above it (the holder hands
/// nothing there), a capture of no cell, or a cell the function made that no
/// other location of its result holds.
fn holderGivesNone(f: *Frame, code: Code, use: *const Use, k: usize) Error!bool {
    const m = f.m;
    const lc = code.contract;
    for (lc.res[k]) |ls| switch (ls.kind) {
        .param => {
            // A capture of no cell (a number) gives none.
            if (ls.a >= code.own_params) {
                if (ls.a - code.own_params >= code.ncaps) return false;
                const cv = try f.capVal(code, ls.a - code.own_params);
                if (cv == v_none or cv == v_outside) continue;
                return false;
            }
            if (ls.a >= use.fnc.arity) return false;
            const pe = m.loc.layoutEntries(lc.layouts[ls.a])[ls.e];
            for (m.loc.layoutEntries(use.fnc.layouts[ls.a])) |he| {
                if (he.loc == pe.loc or (he.kind.wide() and m.loc.isPrefix(he.loc, pe.loc))) return false;
            }
        },
        // A cell the function made that no other location of its result
        // holds: no holder but this place, which no reader names, sees it.
        .fresh => for (lc.res, 0..) |other, ri| {
            if (ri == k) continue;
            for (other) |o| if (o.kind == .fresh and o.a == ls.a) return false;
        },
        .outside, .twice => {},
        .answer => return false,
    };
    return true;
}

/// The holder of `use` can run the known function `code`, and what it hands
/// each function parameter of `code` is a function in the default state: a
/// function that a holder's frame hands on goes to the `top` use there
/// (`mention`), and the default hands one too. So each is the default meeting
/// that parameter's use (`flowUnknown`): what `code` hands it escapes, and a
/// `code` that writes a cell after it handed the cell there is refused, since
/// the default keeps what it is handed (kernel §6.8, report 124 §4 F2). A
/// fresh cell of `code` is named at the holder's key, as in its answer
/// (`answerOfCode`), so a cell handed there and answered is one root.
fn defaultParams(f: *Frame, code: Code, use: *const Use) Error!void {
    const lc = code.contract;
    for (0..@min(code.own_params, lc.arity)) |k| {
        const lf = lc.fns[k] orelse continue;
        var inner = try f.innerUse(code, @intCast(k), lf, use);
        inner.key = use.key;
        try f.escapeSupplies(&inner);
        if (f.rewritesOf(&inner)) try f.refuse(&inner, .supply, "the function changes a value after it handed it to a function parameter, and the code that runs it hands a function that can keep it");
    }
}

/// A captured value is a parameter of the known function's contract, and
/// the function does to it what the contract says where it runs. A write is
/// refused in the function's own frame. A captured value that the function
/// lets escape escapes where the function goes to a holder that can run it.
fn captureEscapes(f: *Frame, code: Code, inst: u32) Error!void {
    const lc = code.contract;
    for (0..code.ncaps) |k| {
        const j = code.own_params + k;
        if (j >= lc.arity) break;
        const n = lc.off[j + 1] - lc.off[j];
        for (0..n) |e| if (lc.flags[lc.off[j] + e] & flag_e != 0) {
            const start: u32 = @intCast(f.atoms.items.len);
            _ = try f.argLeaves(try f.capVal(code, k), lc.layouts[j], @intCast(e), &.{}, false, &f.atoms);
            try f.noteEscape(start, inst);
        };
    }
}

/// Whether the known function `code` writes in place the contents of a
/// cell it captured (kernel §13 item 11).
fn writesCaptured(f: *Frame, code: Code) Error!bool {
    return f.writesCapturedBut(code, &.{});
}

/// `writesCaptured`, but of no capture `k` with `skip[k]` (a writer).
fn writesCapturedBut(f: *Frame, code: Code, skip: []const bool) Error!bool {
    const lc = code.contract;
    for (0..code.ncaps) |k| {
        if (k < skip.len and skip[k]) continue;
        const j = code.own_params + k;
        if (j >= lc.arity) break;
        const inner = try f.innerOf(lc.layouts[j]);
        if (inner.len == 0) continue;
        const n = lc.off[j + 1] - lc.off[j];
        _ = f.charge(Loc.scanUnits(n));
        for (0..n) |e| if (inner[e] and lc.flags[lc.off[j] + e] & flag_w != 0) return true;
    }
    return false;
}

/// The call whose callee runs the function at `use`, or null where a level
/// on the way is the default or loses it: the function then runs at times
/// the frame does not see.
fn runsWithin(use: *const Use) ?*const Use {
    var u = use;
    while (true) {
        if (u.kind == .top or lostAt(u)) return null;
        // A holder that answers the function, or lets it escape, can run it
        // after the call as well: a wrapper `λx → f x` it answers runs `f`
        // where the frame calls the wrapper, any number of times (kernel
        // §13 item 11).
        if (keepsFn(u)) return null;
        if (u.kind == .call) return u;
        u = u.up orelse return null;
    }
}

/// Whether the holder at `use` answers the function at its location, or
/// lets it escape: its contract has `flag_a` or `flag_e` there.
fn keepsFn(use: *const Use) bool {
    if (use.kind == .top or use.j == none) return false;
    const c = use.c;
    if (use.j >= c.arity) return true;
    for (c.flags[c.off[use.j]..c.off[use.j + 1]]) |x| if (x & (flag_a | flag_e) != 0) return true;
    return false;
}

/// What the known function `code` does to the cells it captured, where it
/// runs (kernel §13 item 11). Where a call runs it within the call
/// (`runsWithin`), each write in place of a captured cell's contents is a
/// demand at the call on what the frame holds there now (`capVal`, the
/// latest version), judged by §5 against the call's other operands and the
/// other captures of each function on the way (the callee runs it while it
/// holds those), and each renewal makes a version of the frame's root, which
/// keeps the old contents too where the renewal does not name them (the
/// callee may not run it: `renewHandle`'s `maybe`). A handle that one of
/// those operands holds as well is two names of one cell at the call: a
/// write is refused, and a renewal is one of an argument the frame does not
/// follow (`flowRenews`). Where no call runs the function within, it goes
/// where the walk does not follow it: a write is refused (`flowCode`).
fn captureCells(f: *Frame, v: Val, code: Code, use: *const Use) Error!void {
    const m = f.m;
    const lc = code.contract;
    // The handles of its captures it marks (kernel §13 item 12).
    if (f.cells_any) for (0..code.ncaps) |k| {
        const j = code.own_params + k;
        if (j >= lc.arity) break;
        const sig = lc.layouts[j];
        for (m.loc.layoutEntries(sig), 0..) |he, h| if (he.kind == .cell and lc.flags[lc.off[j] + h] & CMod.flag_m != 0) {
            try f.markHandles(try f.capVal(code, k), sig, @intCast(h));
        };
    };
    const writes = try f.writesCaptured(code);
    if (!writes and !lc.renews()) return;
    const top = runsWithin(use);
    // Where no call runs it within, a capture of a cell the frame made can
    // be a writer, which runs at the frame's switch points (kernel §13 item 12).
    const reg = try f.gpa.alloc(bool, code.ncaps);
    defer f.gpa.free(reg);
    for (reg, 0..) |*x, k| x.* = top == null and f.cells_any and (f.isWriter(code, k) or try f.registerWriter(v, code, @intCast(k), use.site.inst));
    if (top == null and try f.writesCapturedBut(code, reg)) try f.refuse(use, .call, "a function that writes the contents of a cell it captured goes where the checker does not follow it");
    try f.flushShare();
    const site = use.site;
    // The operands the callee holds while it runs the function: the call's
    // other arguments (not the one that holds the function), and the other
    // captures of each function on the way down to `code`.
    var others: std.ArrayList(Other) = .empty;
    defer others.deinit(f.gpa);
    for (site.others, 0..) |o, i| try others.append(f.gpa, if (top != null and i == top.?.j) .{ .v = v_none } else o);
    var u = use;
    while (u.kind == .inner) {
        const up = u.up.?;
        const uc = up.code orelse break;
        for (0..uc.ncaps) |k| {
            const j = uc.own_params + k;
            if (j == u.j or j >= uc.contract.arity) continue;
            try others.append(f.gpa, .{ .v = try f.capVal(uc, k), .sig = uc.contract.layouts[j], .flags = uc.contract.flags[uc.contract.off[j]..uc.contract.off[j + 1]] });
        }
        u = up;
    }
    const first: usize = others.items.len;
    for (0..code.ncaps) |k| {
        const j = code.own_params + k;
        if (j >= lc.arity) break;
        try others.append(f.gpa, .{ .v = try f.capVal(code, k), .sig = lc.layouts[j], .flags = lc.flags[lc.off[j]..lc.off[j + 1]] });
    }
    // The base level of a renewal's sources: the captured values at their
    // parameters; the function's own parameters are what the callee hands
    // it, which no source may name here (`capturedSrcs`).
    const args = try f.gpa.alloc(Val, lc.arity);
    defer f.gpa.free(args);
    @memset(args, v_none);
    for (0..code.ncaps) |k| if (code.own_params + k < lc.arity) {
        args[code.own_params + k] = others.items[first + k].v;
    };
    const bsite: Site = .{ .inst = site.inst, .callee = site.callee };
    // A cell the code made is named as its answer names it at this use
    // (`answerOfCode`): one cell the code stores and answers is one root.
    const base: Use = .{ .kind = .call, .id = f.useId(), .key = use.key, .holder = code.id(), .c = lc, .args = args, .site = &bsite };
    for (0..code.ncaps) |k| {
        const j: u32 = @intCast(code.own_params + k);
        if (j >= lc.arity) break;
        const sig = lc.layouts[j];
        const inner = try f.innerOf(sig);
        if (inner.len == 0) continue;
        const ses = m.loc.layoutEntries(sig);
        const capv = others.items[first + k].v;
        const n = lc.off[j + 1] - lc.off[j];
        var wk = false;
        var rk = false;
        for (0..n) |e| if (inner[e]) {
            if (lc.flags[lc.off[j] + e] & flag_w != 0) wk = true;
            if (lc.renewAt(lc.off[j] + e) != null) rk = true;
        };
        if (!wk and !rk) continue;
        if (reg[k]) continue;
        // The code reads what it writes and renews where it runs, at the
        // cell's version before its renewal: a write of the contents made
        // before the call is judged against that read, as against a direct
        // call's (`apply` reads every argument).
        try f.readBy(capv, site.inst, sig, lc.flags[lc.off[j]..lc.off[j + 1]]);
        // The handles of the capture: is another operand holding one?
        const hs: u32 = @intCast(f.atoms.items.len);
        for (ses, 0..) |he, h| if (he.kind == .cell) {
            _ = try f.argLeaves(capv, sig, @intCast(h), &.{}, false, &f.atoms);
        };
        const handles = try f.gpa.dupe(Atom, f.atoms.items[hs..]);
        defer f.gpa.free(handles);
        f.atoms.shrinkRetainingCapacity(hs);
        const held = for (others.items, 0..) |o, i| {
            if (i == first + k or o.v == v_none) continue;
            if (try f.reach(o.v, handles)) break true;
        } else false;
        // A callee can run the function again within the call while it holds
        // what an earlier run gave it: the cell's contents, or a cell the
        // function stored there and gave it too. The demand at the call is
        // judged once, so such a write is refused.
        if (wk and top != null and handsContents(lc, j, inner)) {
            try f.refuse(use, .disjoint, "a function writes the contents of a cell it captured and hands them, or what it stores there, to the code that runs it, which can run it again");
            continue;
        }
        if (wk and top != null) for (0..n) |e| {
            if (!inner[e] or lc.flags[lc.off[j] + e] & flag_w == 0) continue;
            if (held) {
                try f.refuse(use, .disjoint, "a function writes the contents of a cell it captured, and the callee or another function on the way holds the cell too");
                break;
            }
            const w: u32 = @intCast(f.atoms.items.len);
            const dup = try f.argLeaves(capv, sig, @intCast(e), &.{}, false, &f.atoms);
            // The callee can run the function more than once within the
            // call: a later run writes what an earlier one stored in the
            // cell. So the write is of each value the renewal of the cell's
            // contents names at the written location too: a capture's cells
            // (another location of the cell's own contents among them), outside
            // the frame's (outside, or a value the callee handed, which no rule
            // names here), and not a cell the function made in its run.
            try f.storedAtoms(code, j, @intCast(e));
            try f.demand(w, .{
                .point = site.inst,
                .callee_inst = site.callee,
                .loc = ses[e].loc,
                .others = others.items,
                .arg = first + k,
                .se = @intCast(e),
                .dup = dup and !ses[e].single,
                .list_only = ses[e].kind == .list,
                .kind = .callsite,
            });
        };
        if (!rk) continue;
        if (top != null and !held and capturedSrcs(lc, j, code.own_params, inner)) {
            var done: ?[]bool = null;
            defer if (done) |d| f.gpa.free(d);
            for (ses, 0..) |he, h| {
                if (he.kind != .cell) continue;
                if (done) |d| if (d[h]) continue;
                var ks: std.ArrayList(u32) = .empty;
                defer ks.deinit(f.gpa);
                try f.contentsAt(sig, @intCast(h), &ks);
                const renewed = for (ks.items) |x| {
                    if (lc.renewAt(lc.off[j] + x) != null) break true;
                } else false;
                if (!renewed) continue;
                if (done == null) {
                    done = try f.gpa.alloc(bool, ses.len);
                    @memset(done.?, false);
                }
                for (ks.items) |x| done.?[x] = true;
                try f.renewHandle(&base, lc, j, @intCast(h), ks.items, capv, lc.casts, true, site.inst);
            }
            continue;
        }
        // Not followed: what it stores escapes, and the handle has another holder.
        for (0..n) |e| if (lc.renewAt(lc.off[j] + e)) |srcs| {
            for (srcs) |s| try f.flowStored(code, use, s, site.inst);
        };
        const start = f.atoms.items.len;
        for (ses, 0..) |he, h| if (he.kind == .cell) {
            _ = try f.argLeaves(capv, sig, @intCast(h), &.{}, false, &f.atoms);
        };
        try f.shareAtoms(start, f.atoms.items.len, site.inst);
        f.atoms.shrinkRetainingCapacity(start);
        try f.flushShare();
    }
}

/// Appended to `f.atoms`: what the renewal of capture `j` of `code` names
/// at its entry `e`, which a later run of the code writes where it writes
/// `e` (kernel §13 item 11): a capture's cells (another location of the
/// cell's own contents among them), `outside` for outside the frame or a
/// value the callee handed, and not a cell the code made in its run.
fn storedAtoms(f: *Frame, code: Code, j: u32, e: u32) Error!void {
    const lc = code.contract;
    if (lc.renewAt(lc.off[j] + e)) |srcs| for (srcs) |s| switch (s.kind) {
        .fresh, .twice => {},
        .outside, .answer => try f.atoms.append(f.gpa, outside_atom),
        .param => if (s.a == j and s.e == e) {} else if (s.a >= code.own_params and s.a < lc.arity) {
            _ = try f.argLeaves(try f.capVal(code, s.a - code.own_params), lc.layouts[s.a], s.e, &.{}, false, &f.atoms);
        } else try f.atoms.append(f.gpa, outside_atom),
    };
}

/// Whether the contract `lc` lets the contents of capture parameter `j`
/// (its entries `inner`), or a cell its renewal of them names, reach the
/// code that runs it: its answer, an escape there, or
/// a renewal of another parameter (kernel §13 item 11).
fn handsContents(lc: *const Contract, j: u32, inner: []const bool) bool {
    const n = lc.off[j + 1] - lc.off[j];
    for (0..n) |e| if (inner[e] and lc.flags[lc.off[j] + e] & flag_e != 0) return true;
    const Named = struct {
        fn hit(c: *const Contract, jj: u32, inn: []const bool, x: Src) bool {
            switch (x.kind) {
                .param => return x.a == jj and x.e < inn.len and inn[x.e],
                .fresh => {
                    const nn = c.off[jj + 1] - c.off[jj];
                    for (0..nn) |e| if (inn[e]) if (c.renewAt(c.off[jj] + e)) |srcs| for (srcs) |y| if (y.kind == .fresh and y.a == x.a) return true;
                    return false;
                },
                .outside, .twice, .answer => return false,
            }
        }
    };
    for (lc.res) |srcs| for (srcs) |x| if (Named.hit(lc, j, inner, x)) return true;
    for (0..lc.arity) |a| {
        if (a == j) continue;
        for (lc.off[a]..lc.off[a + 1]) |i| if (lc.renewAt(i)) |srcs| for (srcs) |x| if (Named.hit(lc, j, inner, x)) return true;
    }
    return false;
}

/// Whether every source that the renewals of capture parameter `j` name is
/// a capture of the code, a cell it made or outside the frame: no value the
/// callee hands the code, which the frame cannot name.
fn capturedSrcs(lc: *const Contract, j: u32, own: u32, inner: []const bool) bool {
    const n = lc.off[j + 1] - lc.off[j];
    for (0..n) |e| {
        if (!inner[e]) continue;
        const srcs = lc.renewAt(lc.off[j] + e) orelse continue;
        for (srcs) |s| switch (s.kind) {
            .outside, .twice, .fresh => {},
            .param => if (s.a < own) return false,
            .answer => return false,
        };
    }
    return true;
}

/// Each function that the known function `code` captured is in a location
/// of `code`: its use is `code`'s contract for it, composed with `use`.
fn flowCaptures(f: *Frame, code: Code, use: *const Use) Error!void {
    const lc = code.contract;
    for (0..code.ncaps) |k| {
        const j = code.own_params + k;
        if (j >= lc.arity) break;
        const lf = lc.fns[j] orelse continue;
        const inner = try f.innerUse(code, @intCast(j), lf, use);
        try f.flow(try f.capVal(code, k), &inner);
    }
}

/// The use of capture `j` of the known function `code`, whose own use is `up`.
fn innerUse(f: *Frame, code: Code, j: u32, lf: *const CMod.Fn, up: *const Use) Error!Use {
    const lc = code.contract;
    const args = try f.gpa.alloc(Val, lc.arity);
    @memset(args, v_none);
    for (0..code.ncaps) |k| if (code.own_params + k < lc.arity) {
        args[code.own_params + k] = try f.capVal(code, k);
    };
    return .{ .kind = .inner, .id = f.useId(), .key = std.hash.Wyhash.hash(up.key, std.mem.asBytes(&j)), .holder = code.id(), .c = lc, .fnc = lf, .j = j, .args = args, .own = code.own_params, .up = up, .up_rewrites = f.rewritesOf(up), .site = up.site, .depth = up.depth + 1 };
}

/// The frame's own function parameter meets a use: what the use hands it,
/// this frame hands it. The contract of the frame says so, and the caller
/// that knows the function judges it.
fn flowOwn(f: *Frame, root: u32, use_in: *const Use) Error!void {
    const m = f.m;
    var use = use_in.*;
    use.root = root;
    // The draft of the frame's own function changes as the walk goes on
    // (`lost`, `called`, what it is handed): a judgment that read it is not
    // one that an equal use repeats (`flow`).
    f.ctx_floor = 0;
    const di = try f.draftOf(root, null);
    const inst = use.site.inst;
    f.drafts.items[di].used = true;
    if (use.kind == .top or lostAt(&use) or f.drafts.items[di].lost or f.drafts.items[di].arity != use.fnc.arity) {
        f.drafts.items[di].lost = true;
        if (use.kind != .top) try f.escapeSupplies(&use);
        return;
    }
    if (use.fnc.called) f.drafts.items[di].called = true;
    if (f.rewritesOf(&use)) f.drafts.items[di].rewrites = true;
    var labels: std.ArrayList(u64) = .empty;
    defer labels.deinit(f.gpa);
    for (0..use.fnc.arity) |k| {
        const cov = try m.loc.cover(use.fnc.layouts[k], f.drafts.items[di].layouts[k]);
        for (cov, 0..) |fe, me| {
            const slot = f.drafts.items[di].off[k] + @as(u32, @intCast(me));
            if (fe >= Loc.all) {
                try f.supplyLost(di, slot, inst, &use);
                continue;
            }
            if (!use.fnc.free[use.fnc.off[k] + fe]) f.drafts.items[di].free[slot] = false;
            var sink: DraftSink = .{ .use = &use, .di = di, .slot = slot };
            // The part of the use's entry that this entry of the function's type is
            // (the use is over `a`, the function over `List (List Int)`).
            const part = try f.partBelow(f.drafts.items[di].layouts[k], @intCast(me), use.fnc.layouts[k], fe, &.{}, &labels);
            const wide = m.loc.layoutEntries(f.drafts.items[di].layouts[k])[me].kind.wide();
            for (use.fnc.supply[use.fnc.off[k] + fe]) |s| try f.resolve(&use, s, part, wide, &sink, 0);
        }
    }
}

/// A function in the default state meets a use. It asks nothing; it can keep what it is handed.
fn flowUnknown(f: *Frame, v: Val, use: *const Use) Error!void {
    if (use.kind == .top) return;
    try f.escapeSupplies(use);
    if (lostAt(use)) try f.escape(v, use.site.inst);
    if (f.rewritesOf(use)) try f.refuse(use, .supply, "the callee changes a value after it handed it to a function that the checker does not know");
}

/// What `use` hands the function at its parameter `k`, at entry `le` of
/// `layout` (the function's own reading of that parameter): one slot for
/// each entry of the use's layout that holds a cell of it. The two layouts
/// are two readings of one type, and either can be the wider one:
///
/// - the use's entry at the same location, or a wide one above it (the call
///   map: the use is a fold over `a`, the function is over `List Int`);
/// - each entry of the use below it, when the function's entry is wide (the
///   function is over `a`, the use is over `List (List Int)`).
///
/// `rel`: only the cells at these labels below the function's entry are
/// asked for (an answer at one location below a wide entry comes from the
/// parameter's cells at the same place below it). Null: all of the entry.
///
/// False when no rule follows it. True with no slot: no cell is there.
fn slotsOf(f: *Frame, use: *const Use, k: u32, layout: u32, le: u32, rel: ?[]const u64, out: *std.ArrayList(Slot)) Error!bool {
    const m = f.m;
    if (use.kind == .top) {
        try out.append(f.gpa, .{ .fe = none, .free = false, .srcs = &.{Src.outside} });
        return true;
    }
    const fnc = use.fnc;
    if (k >= fnc.arity) return false;
    const sig = fnc.layouts[k];
    const entry = m.loc.layoutEntries(layout)[le];
    const fe = (try m.loc.cover(sig, layout))[le];
    if (fe < Loc.all) try out.append(f.gpa, .{ .fe = fe, .free = fnc.free[fnc.off[k] + fe], .srcs = fnc.supply[fnc.off[k] + fe] });
    if (entry.kind.wide()) {
        var below: std.ArrayList(u32) = .empty;
        defer below.deinit(f.gpa);
        // Each entry of the use's type that the function's wide entry can
        // hold a cell of: the call map, never label paths (a row covers the
        // fields its record does not name).
        for (0..m.loc.layoutEntries(sig).len) |i| {
            if (i == fe) continue;
            if (try f.locsMeet(sig, @intCast(i), layout, le)) try below.append(f.gpa, @intCast(i));
        }
        if (below.items.len != 0) {
            // The location that is asked for, when the use's type has it.
            var at: ?u32 = if (rel != null) entry.loc else null;
            if (rel) |labels| for (labels) |l| {
                at = m.loc.find(at.?, l);
                if (at == null) break;
            };
            const es = m.loc.layoutEntries(sig);
            if (at) |t| {
                // Only the use's entry at that location, or a wide one above it or whose row holds it.
                var n: usize = 0;
                for (out.items) |slot| {
                    if (es[slot.fe].loc != t and !(es[slot.fe].kind.wide() and m.loc.within(es[slot.fe].loc, t))) continue;
                    out.items[n] = slot;
                    n += 1;
                }
                out.shrinkRetainingCapacity(n);
            }
            for (below.items) |i| {
                if (at) |t| if (es[i].loc != t and !(es[i].kind.wide() and m.loc.within(es[i].loc, t))) continue;
                try out.append(f.gpa, .{ .fe = i, .free = fnc.free[fnc.off[k] + i], .srcs = fnc.supply[fnc.off[k] + i] });
            }
            if (out.items.len == 0) {
                // The use's type has no entry at that place: each cell of the wide entry, not "no cell".
                if (fe < Loc.all) try out.append(f.gpa, .{ .fe = fe, .free = fnc.free[fnc.off[k] + fe], .srcs = fnc.supply[fnc.off[k] + fe] });
                for (below.items) |i| try out.append(f.gpa, .{ .fe = i, .free = fnc.free[fnc.off[k] + i], .srcs = fnc.supply[fnc.off[k] + i] });
            }
            return true;
        }
    }
    if (fe < Loc.all) return true;
    // No entry of the use's type is there. A type with no object at the
    // location (a function over `List a`, handed a `List Int`) hands no
    // cell: no entry of it meets the function's entry.
    return !try f.anyMeets(sig, layout, le);
}

/// Whether some entry of layout `ul` can name a cell of entry `k` of layout `fl` (`locsMeet`).
fn anyMeets(f: *Frame, ul: u32, fl: u32, k: u32) Error!bool {
    for (0..f.m.loc.layoutEntries(ul).len) |i| if (try f.locsMeet(ul, @intCast(i), fl, k)) return true;
    return false;
}

/// Whether the function's result entry `k` of layout `fl` can hold a cell
/// of the use's answer entry `ae` of layout `ul`; `cv` is the call map's
/// entry for `k`. The other direction of `slotsOf`: a wide entry of the
/// function holds each cell of the use's entries below it, or in its row
/// (`locsMeet`).
fn answersAt(f: *Frame, ul: u32, ae: u32, fl: u32, k: usize, cv: u32) Error!bool {
    if (Loc.hits(cv, ae)) return true;
    return f.locsMeet(ul, ae, fl, @intCast(k));
}

/// `answersAt` of one entry `ae` of the use's layout `ul` against each entry `k` of the
/// function's layout `fl`, the entry `k` maps to through `cover(ul, fl)` given:
/// `locsMeet` reads the two maps for each pair, and here the map the other way is
/// read once for `ae`. The answer is `answersAt`'s, pair for pair (safe builds check
/// it for layouts of at most 64 entries).
const AnswersAt = struct {
    uls: []const Loc.Entry,
    fls: []const Loc.Entry,
    ae: u32,
    ba: u32,

    fn init(f: *Frame, ul: u32, ae: u32, fl: u32) Error!AnswersAt {
        const m = f.m;
        return .{ .uls = m.loc.layoutEntries(ul), .fls = m.loc.layoutEntries(fl), .ae = ae, .ba = (try m.loc.cover(fl, ul))[ae] };
    }

    fn at(s: AnswersAt, k: usize, cv: u32) bool {
        if (Loc.hits(cv, s.ae)) return true;
        const ab_decides = cv < Loc.all and (!s.fls[k].kind.wide() or s.uls[cv].kind.wide());
        const ba_decides = s.ba < Loc.all and (!s.uls[s.ae].kind.wide() or s.fls[s.ba].kind.wide());
        if (ab_decides and cv == s.ae) return true;
        if (ba_decides and s.ba == k) return true;
        return !(ab_decides or ba_decides);
    }

    fn check(s: AnswersAt, f: *Frame, ul: u32, fl: u32, k: usize, cv: u32) Error!bool {
        const got = s.at(k, cv);
        if (safety and smallLayout(f, ul) and smallLayout(f, fl)) std.debug.assert(got == try f.answersAt(ul, s.ae, fl, k, cv));
        return got;
    }
};

/// What the source `src` of `use`'s contract is in this frame: `sink` gets
/// each part. `suffix`: only the part at these labels below the source's
/// entry; `deep`: and each cell below that part (the one that asks is a wide
/// location). A parameter of a known function that has the location is what
/// that function's own use hands it: this is the composition.
fn resolve(f: *Frame, use: *const Use, src: Src, suffix: []const u64, deep: bool, sink: anytype, depth: u32) Error!void {
    if (f.tick()) return;
    switch (src.kind) {
        // A cell the holder made: its one root at this call, an atom like any other (kernel §4.2).
        .fresh => {
            const start: u32 = @intCast(f.atoms.items.len);
            // A source of a known function's contract at an inner use is a cell
            // of that function, made in the run its own use names: the key of
            // that use, as `answerSrcs` names the cells it answers. With the inner
            // use's key, one cell that the function hands a captured function
            // and answers had two names (kernel §4.2).
            const key = if (use.kind == .inner) use.up.?.key else use.key;
            try f.freshAtom(key, use.holder, f.m.isDraft(use.c), src.a, src.e != 0, use.site.inst, &f.atoms);
            try sink.atoms(f, .{ .start = start, .dup = false, .use = use, .a = none, .e = 0, .suffix = suffix, .captured = false });
        },
        .outside => try sink.outside(f),
        // A supply is never a result entry, so `twice` does not reach here
        // (`supplyAtoms` makes supplies from atoms); read as `outside` if it did.
        .twice => {
            if (safety) std.debug.assert(false);
            try sink.outside(f);
        },
        .answer => try sink.answer(f, use, src, suffix, deep),
        .param => {
            if (src.a >= use.args.len) return sink.lost(f, use);
            if (use.kind == .inner and src.a < use.own) {
                const up = f.upOf(use).?;
                // The default hands a value outside the frame.
                if (up.kind == .top) return sink.outside(f);
                if (depth > 12) return sink.lost(f, use);
                const lc = use.c;
                var slots: std.ArrayList(Slot) = .empty;
                defer slots.deinit(f.gpa);
                if (!try f.slotsOf(up, src.a, lc.layouts[src.a], src.e, null, &slots)) return sink.lost(f, use);
                var labels: std.ArrayList(u64) = .empty;
                defer labels.deinit(f.gpa);
                const wide = deep or f.m.loc.layoutEntries(lc.layouts[src.a])[src.e].kind.wide();
                for (slots.items) |slot| {
                    if (!slot.free) try sink.held(f);
                    // The part of the use's entry that the function's entry is. An
                    // entry of the use below the function's entry is all of it.
                    const part = try f.partBelow(lc.layouts[src.a], src.e, up.fnc.layouts[src.a], slot.fe, suffix, &labels);
                    for (slot.srcs) |ss| try f.resolve(up, ss, part, wide, sink, depth + 1);
                }
                return;
            }
            const start: u32 = @intCast(f.atoms.items.len);
            const dup = try f.argLeaves(use.args[src.a], use.c.layouts[src.a], src.e, suffix, deep, &f.atoms);
            try sink.atoms(f, .{ .start = start, .dup = dup, .use = use, .a = src.a, .e = src.e, .suffix = suffix, .captured = use.kind == .inner });
        },
    }
}

/// The parts of a source as atoms and flags: what an answer can hold.
const FlatSink = struct {
    st: *SrcState,
    depth: u32,

    fn outside(_: *FlatSink, f: *Frame) Error!void {
        try f.atoms.append(f.gpa, outside_atom);
    }
    /// The holder can hand one cell to two calls: two answers can be that cell.
    fn held(s: *FlatSink, _: *Frame) Error!void {
        s.st.twice = true;
    }
    fn lost(s: *FlatSink, f: *Frame, use: *const Use) Error!void {
        try f.lostAnswer(use, s.st);
    }
    fn atoms(s: *FlatSink, f: *Frame, h: Handed) Error!void {
        s.st.handed = true;
        if (h.dup) s.st.twice = true;
        if (h.captured) {
            // Each run is handed the same cell: two runs can answer it. The answer holds it.
            s.st.twice = true;
            return;
        }
        if (h.a == none) return;
        const c = h.use.c;
        if (c.flags[c.off[h.a] + h.e] & (flag_w | flag_s) != 0) f.oldNames(h.start, s.st);
    }
    fn answer(s: *FlatSink, f: *Frame, level: *const Use, src: Src, suffix: []const u64, deep: bool) Error!void {
        // A wide location asks: each part of the answer below the place, not the one at it.
        const outer = s.st.whole;
        if (deep) s.st.whole = true;
        defer s.st.whole = outer;
        try f.answerOfParam(level, src, suffix, s.st, s.depth + 1);
    }
};

/// The parts of a source escape: the function keeps what it is handed there.
const EscSink = struct {
    inst: u32,

    /// A cell outside the frame is held outside it already.
    fn outside(_: *EscSink, _: *Frame) Error!void {}
    fn held(_: *EscSink, _: *Frame) Error!void {}
    fn lost(s: *EscSink, f: *Frame, use: *const Use) Error!void {
        var u: ?*const Use = use;
        while (u) |x| : (u = f.upOf(x)) for (x.args) |v| try f.escape(v, s.inst);
    }
    fn atoms(s: *EscSink, f: *Frame, h: Handed) Error!void {
        try f.noteEscape(h.start, s.inst);
    }
    fn answer(s: *EscSink, f: *Frame, level: *const Use, src: Src, suffix: []const u64, _: bool) Error!void {
        // The own answer of a function that the frame does not know holds
        // what the function is handed and what it captured: both are judged
        // where they are handed and held.
        if (src.a == level.j and level.code == null) return;
        const start: u32 = @intCast(f.atoms.items.len);
        var st: SrcState = .{ .inst = s.inst, .whole = true };
        try f.answerOfParam(level, src, suffix, &st, 0);
        try f.noteEscape(start, s.inst);
    }
};

/// The parts of a source must be `own`: a known function writes what it is handed there.
const OwnSink = struct {
    level: *const Use,
    seen: *Seen,

    fn outside(s: *OwnSink, f: *Frame) Error!void {
        try f.refuse(s.level, .supply, "the callee hands the function a value that it does not own");
    }
    fn held(s: *OwnSink, f: *Frame) Error!void {
        try f.refuse(s.level, .supply, "the function writes a parameter that the callee reads again or does not hand as its own");
    }
    fn lost(s: *OwnSink, f: *Frame, _: *const Use) Error!void {
        try f.refuse(s.level, .supply, "the function writes a parameter, and the checker cannot follow what it is handed there");
    }
    fn atoms(s: *OwnSink, f: *Frame, h: Handed) Error!void {
        const m = f.m;
        if (h.captured) return f.refuse(s.level, .supply, "the function writes a parameter that is handed a captured value in each run");
        if (f.atoms.items.len == h.start) return;
        const site = s.level.site;
        // A cell the callee made (`h.a == none`): the write is judged as a
        // write of that cell, with no argument to name.
        var loc: u32 = 0;
        var single = true;
        if (h.a != none) {
            const sig = h.use.c.layouts[h.a];
            loc = m.loc.layoutEntries(sig)[h.e].loc;
            for (h.suffix) |l| loc = try m.loc.extend(loc, @bitCast(l));
            // The written location, below the handed entry: a summary
            // location there is no single place, though the entry is (a
            // function value handed a whole list writes its elements; kernel
            // §5, test 1). Research report 154's second review: `app [ r, r ]
            // λl → …` wrote `r` at two places of the list.
            single = !m.loc.loc_summary.items[loc];
        }
        try f.demand(h.start, .{
            .point = site.inst,
            .callee_inst = site.callee,
            .base_inst = if (h.a != none and h.a < site.arg_insts.len) site.arg_insts[h.a].int() else none,
            .loc = loc,
            .others = site.others,
            .arg = if (h.a == none) std.math.maxInt(usize) else h.a,
            .se = if (h.a == none) none else h.e,
            .suffix = h.suffix,
            .dup = h.dup and !single,
            .kind = .callsite,
        });
    }
    fn answer(s: *OwnSink, f: *Frame, level: *const Use, src: Src, suffix: []const u64, deep: bool) Error!void {
        if (src.a != level.j) return f.refuse(s.level, .supply, "the callee hands the function the answer of another function");
        // The function's own answer comes back to it (a fold): what it answers at the written part must be `own`.
        try f.answerOwn(level, src.e, suffix, deep, s.seen);
    }
};

/// The parts of a source are what the frame hands its own function parameter.
const DraftSink = struct {
    use: *const Use,
    di: u32,
    slot: u32,

    fn add(s: *DraftSink, f: *Frame, src: Src) Error!void {
        try f.drafts.items[s.di].supply[s.slot].append(f.gpa, src);
    }
    fn outside(s: *DraftSink, f: *Frame) Error!void {
        try s.add(f, Src.outside);
    }
    fn held(s: *DraftSink, f: *Frame) Error!void {
        f.drafts.items[s.di].free[s.slot] = false;
    }
    fn lost(s: *DraftSink, f: *Frame, _: *const Use) Error!void {
        try f.supplyLost(s.di, s.slot, s.use.site.inst, s.use);
    }
    fn atoms(s: *DraftSink, f: *Frame, h: Handed) Error!void {
        const site = s.use.site;
        if (h.captured) {
            // A captured value: handed in each run.
            f.drafts.items[s.di].free[s.slot] = false;
            return f.supplyAtoms(s.di, s.slot, h.start, site.inst, site.others, std.math.maxInt(usize), none, h.dup);
        }
        try f.supplyAtoms(s.di, s.slot, h.start, site.inst, site.others, if (h.a == none) std.math.maxInt(usize) else h.a, if (h.a == none) none else h.e, h.dup);
    }
    fn answer(s: *DraftSink, f: *Frame, level: *const Use, src: Src, suffix: []const u64, deep: bool) Error!void {
        const m = f.m;
        const site = s.use.site;
        if (level.id == s.use.id and src.a == s.use.j) {
            // The function's own answer comes back to it: the contract says so.
            const dr = f.drafts.items[s.di];
            const index: u16 = @intCast(f.roots.items[dr.root].index);
            const acov = try m.loc.cover(s.use.fnc.layouts[s.use.fnc.arity], dr.layouts[dr.arity]);
            // The answer's entry at the same part below the use's entry, when it has one.
            var want: ?u32 = m.loc.layoutEntries(s.use.fnc.layouts[s.use.fnc.arity])[src.e].loc;
            for (suffix) |l| {
                want = m.loc.find(want.?, l);
                if (want == null) break;
            }
            // The scan of the answer's layout and of the map is work (kernel §8).
            _ = f.charge(Loc.scanUnits(m.loc.layoutEntries(dr.layouts[dr.arity]).len) + Loc.scanUnits(acov.len));
            var exact = false;
            if (!deep) if (want) |wl| for (m.loc.layoutEntries(dr.layouts[dr.arity]), 0..) |de, ae| if (de.loc == wl and Loc.hits(acov[ae], src.e)) {
                exact = true;
            };
            for (acov, 0..) |cv, ae| {
                if (!Loc.hits(cv, src.e)) continue;
                if (exact and m.loc.layoutEntries(dr.layouts[dr.arity])[ae].loc != want.?) continue;
                try s.add(f, .{ .kind = .answer, .a = index, .e = @intCast(ae) });
            }
            return;
        }
        // The answer of another function: what it can hold, each cell an atom.
        const w: u32 = @intCast(f.atoms.items.len);
        var st: SrcState = .{ .inst = site.inst, .whole = true };
        try f.answerOfParam(level, src, suffix, &st, 0);
        if (st.twice) f.drafts.items[s.di].free[s.slot] = false;
        try f.supplyAtoms(s.di, s.slot, w, site.inst, site.others, std.math.maxInt(usize), none, st.twice);
    }
};

/// The known function `code`, in the location of `level`, writes its
/// parameter `k` at its entry `le`: each source of what `level` hands there
/// must be `own`, and the holder must not read it again.
fn ownSupply(f: *Frame, level: *const Use, code: Code, k: u32, le: u32, seen: *Seen) Error!void {
    if (f.tick()) return;
    const lc = code.contract;
    const not_own = "the function writes a parameter that the callee reads again or does not hand as its own";
    var slots: std.ArrayList(Slot) = .empty;
    defer slots.deinit(f.gpa);
    if (!try f.slotsOf(level, k, lc.layouts[k], le, null, &slots)) return f.refuse(level, .supply, not_own);
    for (slots.items) |slot| if (!slot.free) return f.refuse(level, .supply, not_own);
    if (slots.items.len == 0) return;
    switch (seen.visit(level, k, le)) {
        .new => {},
        .old => return,
        .full => return f.refuse(level, .supply, "the supply of a function parameter is too deep to follow"),
    }
    var labels: std.ArrayList(u64) = .empty;
    defer labels.deinit(f.gpa);
    var sink: OwnSink = .{ .level = level, .seen = seen };
    const wide = f.m.loc.layoutEntries(lc.layouts[k])[le].kind.wide();
    for (slots.items) |slot| {
        // The part below the holder's entry that the function writes.
        const part = try f.partBelow(lc.layouts[k], le, level.fnc.layouts[k], slot.fe, &.{}, &labels);
        for (slot.srcs) |src| try f.resolve(level, src, part, wide, &sink, 0);
    }
}

/// The labels of entry `le` of the function's layout `fl` below entry `fe`
/// of the use's layout `ul`, then `suffix`. Empty when the use's entry is
/// below the function's: all of it is a part of the function's entry. The
/// suffix is dropped then, on purpose: the answer is each cell of the use's
/// entry, which is more than the part that was asked for and never less.
fn partBelow(f: *Frame, fl: u32, le: u32, ul: u32, fe: u32, suffix: []const u64, labels: *std.ArrayList(u64)) Error![]const u64 {
    const m = f.m;
    if (fe == none) return &.{};
    const floc = m.loc.layoutEntries(fl)[le].loc;
    const uloc = m.loc.layoutEntries(ul)[fe].loc;
    if (uloc != floc and m.loc.isPrefix(floc, uloc)) return &.{};
    if (!m.loc.isPrefix(uloc, floc)) return &.{};
    try f.suffixOf(floc, uloc, labels);
    try labels.appendSlice(f.gpa, suffix);
    return f.gpa.dupe(u64, labels.items);
}

/// The answer of the function in the location of `level`, at entry `e`,
/// comes back to it, and it is written then. So the answer must be `own`:
/// made by the function, or a parameter that it was handed as its own and
/// did not let go.
fn answerOwn(f: *Frame, level: *const Use, e: u32, suffix: []const u64, deep: bool, seen: *Seen) Error!void {
    if (f.tick()) return;
    const m = f.m;
    const not_own = "the function answers a value that it does not own, and the callee hands it back";
    const code = level.code orelse return f.refuse(level, .supply, not_own);
    const lc = code.contract;
    const fnc = level.fnc;
    switch (seen.visit(level, none, e)) {
        .new => {},
        // In work already: it is `own` if the rest is (the largest solution).
        .old => return,
        .full => return f.refuse(level, .supply, "the supply of a function parameter is too deep to follow"),
    }
    // The answer comes back as the function's parameter, whose locations are
    // apart. So the answer must hold each cell once.
    if (lc.nonlinear) {
        return f.refuse(level, .supply, "the function can answer one cell at two places, and the callee hands the answer back");
    }
    const rcov = try m.loc.cover(fnc.layouts[fnc.arity], lc.layouts[lc.arity]);
    var want: ?u32 = m.loc.layoutEntries(fnc.layouts[fnc.arity])[e].loc;
    for (suffix) |l| {
        want = m.loc.find(want.?, l);
        if (want == null) break;
    }
    // The scan of the answer's layout and of the map is work (kernel §8).
    _ = f.charge(Loc.scanUnits(m.loc.layoutEntries(lc.layouts[lc.arity]).len) + Loc.scanUnits(rcov.len));
    var exact = false;
    if (!deep) if (want) |wl| for (m.loc.layoutEntries(lc.layouts[lc.arity]), 0..) |re_e, re| if (re_e.loc == wl and Loc.hits(rcov[re], e)) {
        exact = true;
    };
    const meets = try AnswersAt.init(f, fnc.layouts[fnc.arity], e, lc.layouts[lc.arity]);
    for (rcov, 0..) |cv, re| {
        if (!try meets.check(f, fnc.layouts[fnc.arity], lc.layouts[lc.arity], re, cv)) continue;
        if (exact and m.loc.layoutEntries(lc.layouts[lc.arity])[re].loc != want.?) continue;
        if (cv >= Loc.all and !try f.anyMeets(fnc.layouts[fnc.arity], lc.layouts[lc.arity], @intCast(re))) continue;
        for (lc.res[re]) |ls| switch (ls.kind) {
            // A cell the function made is its own only where the contract
            // names no other holder of it: it did not escape, it is at no
            // other location of the answer, and it was handed to no function.
            .fresh => if (!freshOwn(m, lc, @intCast(re), ls)) {
                try f.refuse(level, .supply, "the function answers a cell that it made and let go, and the callee hands it back");
            },
            .outside, .twice => try f.refuse(level, .supply, not_own),
            .answer => {
                // The answer of a function that this one captured: `own` in its turn.
                if (ls.a < code.own_params or ls.a - code.own_params >= code.ncaps or ls.a >= lc.arity) {
                    try f.refuse(level, .supply, not_own);
                    continue;
                }
                const lf = lc.fns[ls.a] orelse {
                    try f.refuse(level, .supply, not_own);
                    continue;
                };
                const cc = (try f.codeOf(try f.capVal(code, ls.a - code.own_params))) orelse {
                    try f.refuse(level, .supply, not_own);
                    continue;
                };
                // The function lets that answer escape too: it is held somewhere else.
                if (lf.ans_escapes or lf.lost or cc.own_params != lf.arity) {
                    try f.refuse(level, .supply, not_own);
                    continue;
                }
                // The function must answer that answer as it is, and one time:
                // at the same location, at no other place of its result, and
                // handed to no function. (`[ r, r ]` has one cell at two places.)
                if (!f.passesOn(code, @intCast(re), ls, lf)) {
                    try f.refuse(level, .supply, not_own);
                    continue;
                }
                var inner = try f.innerUse(code, ls.a, lf, level);
                inner.code = cc;
                try f.answerOwn(&inner, ls.e, &.{}, true, seen);
            },
            .param => {
                if (ls.a >= code.own_params) {
                    try f.refuse(level, .supply, "the function answers a captured value, and the callee hands it back");
                    continue;
                }
                if (lc.flags[lc.off[ls.a] + ls.e] & flag_e != 0) {
                    try f.refuse(level, .supply, "the function lets a value escape and answers it, and the callee hands it back");
                    continue;
                }
                try f.handedBack(level, code, ls.a, ls.e);
                try f.ownSupply(level, code, ls.a, ls.e, seen);
            },
        };
    }
}

/// Whether two locations of one layout can hold one cell (kernel §11): a
/// field slot is no list, and the slots of two fields are two cells. One
/// site of a callee's wide location (a builder's elements, `fresh`) is at
/// each of the caller's slots below it, and names a cell of each.
fn canShare(m: *Mod, a: Loc.Entry, b: Loc.Entry) bool {
    if ((a.kind == .field) != (b.kind == .field)) return a.kind.wide() or b.kind.wide();
    if (a.kind != .field) return true;
    const la: Loc.Label = @bitCast(m.loc.loc_label.items[a.loc]);
    const lb: Loc.Label = @bitCast(m.loc.loc_label.items[b.loc]);
    return la.payload == lb.payload;
}

/// Whether the cell `ls` that a function made, which its contract `lc`
/// answers at result entry `re`, has no other holder that the contract
/// names (kernel §6.8). Every negative fact here is read off positive
/// sources: a source of that site with the escape bit, the same site at
/// another result entry, or the same site in what the function hands a
/// function parameter (which can keep it).
fn freshOwn(m: *Mod, lc: *const Contract, re: u32, ls: Src) bool {
    if (ls.e != 0) return false;
    const res = m.loc.layoutEntries(lc.layouts[lc.arity]);
    for (lc.res, 0..) |srcs, k| for (srcs) |x| if (x.kind == .fresh and x.a == ls.a) {
        if (x.e != 0) return false;
        if (k != re and canShare(m, res[k], res[re])) return false;
    };
    for (lc.fns) |lfo| {
        const g = lfo orelse continue;
        for (g.supply) |srcs| for (srcs) |x| if (x.kind == .fresh and x.a == ls.a) return false;
    }
    // A cell the call leaves in a cell it was handed or captured is held
    // there too (kernel §13 items 3 and 11).
    for (lc.renew) |ro| if (ro) |srcs| for (srcs) |x| if (x.kind == .fresh and x.a == ls.a) return false;
    return true;
}

/// Whether the parameter location `ls` that contract `lc` answers at
/// result entry `re` has no other holder that the contract names: the body
/// did not let it escape, answers it at no other entry, and handed it to no
/// function (kernel §6.13).
fn paramOwn(lc: *const Contract, re: u32, ls: Src) bool {
    if (ls.a >= lc.arity or lc.flags[lc.off[ls.a] + ls.e] & flag_e != 0) return false;
    // A location the call leaves in a cell is held there too (kernel §13).
    for (lc.renew) |ro| if (ro) |srcs| for (srcs) |x| if (x.kind == .param and x.a == ls.a and x.e == ls.e) return false;
    // A contract that says no cell of a parameter is at two locations of
    // its result answers the location at one of them in each run, though
    // its arms answer it at two (`{ m | w = m.w2, w2 = m.w }` in one arm,
    // `m.w` at `.w` in another): kernel §6 rule 13, *One value of a join at a
    // time*; research report 159. Where it can be, every other entry that
    // holds it is another holder.
    if (lc.nonlinear) for (lc.res, 0..) |srcs, k| {
        if (k == re) continue;
        for (srcs) |x| if (x.kind == .param and x.a == ls.a and x.e == ls.e) return false;
    };
    return !handsOn(lc, ls.a, ls.e);
}

/// Whether contract `lc` hands parameter location `(a, e)` to one of its
/// function parameters or captured functions, which can keep it.
fn handsOn(lc: *const Contract, a: u32, e: u32) bool {
    for (lc.fns) |lfo| {
        const g = lfo orelse continue;
        for (g.supply) |srcs| for (srcs) |x| if (x.kind == .param and x.a == a and x.e == e) return true;
    }
    return false;
}

/// Whether the known function `code` answers the answer `ls` of a function
/// that it captured as it is: at result entry `re`, which is the same
/// location as the answer's entry; at no other entry of the result; and it
/// hands that answer to no function.
fn passesOn(f: *Frame, code: Code, re: u32, ls: Src, lf: *const CMod.Fn) bool {
    const m = f.m;
    const lc = code.contract;
    if (m.loc.layoutEntries(lc.layouts[lc.arity])[re].loc != m.loc.layoutEntries(lf.layouts[lf.arity])[ls.e].loc) return false;
    for (lc.res, 0..) |srcs, k| {
        if (k == re) continue;
        for (srcs) |x| if (x.kind == .answer and x.a == ls.a and x.e == ls.e) return false;
    }
    for (lc.fns) |lfo| {
        const g = lfo orelse continue;
        for (g.supply) |srcs| for (srcs) |x| if (x.kind == .answer and x.a == ls.a and x.e == ls.e) return false;
    }
    return true;
}

/// The known function `code` answers its parameter `(a, e)`, the holder
/// hands that answer back, and the function writes it then. A function that
/// `code` handed the cell to must not keep it.
fn handedBack(f: *Frame, level: *const Use, code: Code, a: u32, e: u32) Error!void {
    const lc = code.contract;
    for (lc.fns, 0..) |lfo, jj| {
        const lf = lfo orelse continue;
        var handed = false;
        for (lf.supply) |srcs| for (srcs) |x| if (x.kind == .param and x.a == a and x.e == e) {
            handed = true;
        };
        if (!handed) continue;
        if (jj < code.own_params or jj - code.own_params >= code.ncaps) {
            try f.refuse(level, .supply, "the function hands on a value that it answers, and the callee hands it back");
            continue;
        }
        const cv = try f.capVal(code, jj - code.own_params);
        const root = f.ownFnRoot(cv);
        if (f.isFnRoot(root)) {
            // The frame's own function: its contract says that the cell changes later.
            const di = try f.draftOf(root, null);
            f.drafts.items[di].rewrites = true;
            continue;
        }
        if (try f.codeOf(cv)) |cc| {
            if (!f.keepsOwn(cc.contract, cc.own_params)) continue;
        }
        try f.refuse(level, .supply, "the function hands a value to a function that can keep it, answers it, and the callee hands it back");
    }
}

/// The answer root of the frame's own function parameter at `root`, in the
/// call in work: its atoms at the entries that the answer entry `ae` of
/// layout `alayout` covers.
fn ownAnswer(f: *Frame, root: u32, alayout: u32, ae: u32, st: *SrcState) Error!void {
    st.handed = true;
    const di = try f.draftOf(root, null);
    f.drafts.items[di].used = true;
    const ai = try f.answerRoot(di, st.inst);
    // The answer can hold the function itself, and what it captured: as at
    // a call (`callParam`), so that where the answer escapes the function
    // does too, and what its holder hands it there (kernel §13: a callee
    // that stores the answer of a function parameter in a cell the frame
    // does not follow).
    const self: Atom = .{ .root = root, .path = f.roots.items[root].path, .e = 0 };
    const base = &f.answers.items[ai].base;
    if (for (base.items) |b| {
        if (atomEql(b, self)) break false;
    } else true) try base.append(f.gpa, self);
    const root_id = f.answers.items[ai].root;
    const ar = f.roots.items[root_id];
    const dr = f.drafts.items[di];
    const cov = try f.m.loc.cover(alayout, dr.layouts[dr.arity]);
    // The map read the other way, made once for each pair of layouts in a
    // frame (`coverHits`): each entry asked costs the entries it finds, in
    // the order a scan of the map finds them (kernel §8; research report 159).
    var hit: std.ArrayList(u32) = .empty;
    defer hit.deinit(f.gpa);
    try f.coverHits(alayout, dr.layouts[dr.arity], cov, ae, &hit);
    _ = f.charge(1 + hit.items.len);
    for (hit.items) |k| try f.atoms.append(f.gpa, .{ .root = root_id, .path = ar.path, .e = k });
}

/// No rule follows this answer. It has no claim, and it can hold a cell of
/// each value in sight: each argument of the call, and each value that a
/// known function on the way captured. A location with no claim keeps what
/// it can hold (report 111 §3.5).
fn lostAnswer(f: *Frame, use: *const Use, st: *SrcState) Error!void {
    st.handed = true;
    try f.atoms.append(f.gpa, outside_atom);
    var u: ?*const Use = use;
    while (u) |x| : (u = f.upOf(x)) for (x.args) |a| {
        _ = try f.allLeaves(a, &f.atoms);
    };
}

/// The answer of the function at parameter `src.a` of `level`'s contract, at its entry `src.e`.
fn answerOfParam(f: *Frame, level: *const Use, src: Src, suffix: []const u64, st: *SrcState, depth: u32) Error!void {
    const outer = st.suffix;
    st.suffix = try f.gpa.dupe(u64, suffix);
    defer st.suffix = outer;
    if (level.kind == .top) return f.lostAnswer(level, st);
    if (src.a == level.j) {
        // The function in the location itself.
        if (level.code) |code| return f.answerOfCode(code, level, src.e, st, depth);
        if (level.root != none) return f.ownAnswer(level.root, level.fnc.layouts[level.fnc.arity], src.e, st);
        return f.lostAnswer(level, st);
    }
    // Another function of the same holder.
    if (src.a >= level.args.len or src.a >= level.c.arity or (level.kind == .inner and src.a < level.own)) return f.lostAnswer(level, st);
    const fnc = level.c.fns[src.a] orelse return f.lostAnswer(level, st);
    var other = level.*;
    other.fnc = fnc;
    other.j = src.a;
    other.code = null;
    other.root = none;
    // The same holder, another of its function parameters: the same key, so
    // a fresh cell of that function's answer is one root wherever it is read.
    try f.answerOf(level.args[src.a], &other, src.e, st, depth);
}

/// Append to `f.atoms` what the answer of the function value `v`, in the
/// location of `use`, can hold at the answer entry `ae`.
fn answerOf(f: *Frame, v: Val, use: *const Use, ae: u32, st: *SrcState, depth: u32) Error!void {
    if (f.tick()) return;
    if (v == v_none) return;
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        for (0..n.b) |ki| try f.answerOf(f.lists.items[n.a + 2 * ki], use, ae, st, depth);
        return;
    }
    if (try f.codeOf(v)) |code| {
        var u = use.*;
        u.code = code;
        return f.answerOfCode(code, &u, ae, st, depth);
    }
    const root = f.ownFnRoot(v);
    // The frame's own function parameter answers through its own contract; anything else has no claim.
    if (f.isFnRoot(root) and use.kind != .top) return f.ownAnswer(root, use.fnc.layouts[use.fnc.arity], ae, st);
    return f.lostAnswer(use, st);
}

/// What the known function `code`, in the location of `use`, answers at the entry `ae`.
fn answerOfCode(f: *Frame, code: Code, use: *const Use, ae: u32, st: *SrcState, depth: u32) Error!void {
    if (f.tick()) return;
    const m = f.m;
    if (use.kind == .top or depth > 8 or code.own_params != use.fnc.arity) return f.lostAnswer(use, st);
    const fnc = use.fnc;
    const lc = code.contract;
    // A function that casts answers what it was handed at a depth no type
    // names, and its holder hands it values through the holder's own
    // layout, which can have no location for them (an `Int` that a cast made
    // of a list): where the holder reads the answer at a location that is not
    // wide, nothing names what is there, and the answer is lost (kernel §3.4,
    // *A cast function in a holder*). Research report 158's second review:
    // `(λy → k y) n` with `k = Pun.conv` answered a list nobody held.
    if (lc.casts and !m.loc.layoutEntries(fnc.layouts[fnc.arity])[ae].kind.wide()) return f.lostAnswer(use, st);
    const cov = try m.loc.cover(fnc.layouts[fnc.arity], lc.layouts[lc.arity]);
    // The known function's result entry at the same part below the answer, when it has one.
    var want: ?u32 = m.loc.layoutEntries(fnc.layouts[fnc.arity])[ae].loc;
    for (st.suffix) |l| {
        want = m.loc.find(want.?, l);
        if (want == null) break;
    }
    // The scan of the answer's layout and of the map is work (kernel §8).
    _ = f.charge(Loc.scanUnits(m.loc.layoutEntries(lc.layouts[lc.arity]).len) + Loc.scanUnits(cov.len));
    var exact = false;
    if (!st.whole) if (want) |wl| for (m.loc.layoutEntries(lc.layouts[lc.arity]), 0..) |re_e, re| if (re_e.loc == wl and Loc.hits(cov[re], ae)) {
        exact = true;
    };
    var psuffix: std.ArrayList(u64) = .empty;
    defer psuffix.deinit(f.gpa);
    const meets = try AnswersAt.init(f, fnc.layouts[fnc.arity], ae, lc.layouts[lc.arity]);
    for (cov, 0..) |cv, k| {
        if (!try meets.check(f, fnc.layouts[fnc.arity], lc.layouts[lc.arity], k, cv)) continue;
        if (exact and m.loc.layoutEntries(lc.layouts[lc.arity])[k].loc != want.?) continue;
        // The function's type is wider here than the holder's: no cell is there.
        if (cv >= Loc.all and !try f.anyMeets(fnc.layouts[fnc.arity], lc.layouts[lc.arity], @intCast(k))) continue;
        switch (st.visit(use, @intCast(k))) {
            .new => {},
            // In work already: it adds no cell.
            .old => continue,
            .full => return f.lostAnswer(use, st),
        }
        try f.answerSrcs(code, use, k, cv, ae, st, depth, &psuffix);
    }
}

/// What the result entry `k` of the known function `code`, in the location
/// of `use`, holds: its sources read in the use. `cv` is the call map's
/// entry for `k`, and `ae` the use's answer entry asked, if any (the part
/// of a parameter at the same place below it).
fn answerSrcs(f: *Frame, code: Code, use: *const Use, k: usize, cv: u32, ae: ?u32, st: *SrcState, depth: u32, psuffix: *std.ArrayList(u64)) Error!void {
    const m = f.m;
    const fnc = use.fnc;
    const lc = code.contract;
    for (lc.res[k]) |ls| switch (ls.kind) {
        // A cell the function made: one root at this holder for its name (kernel §4.2).
        .fresh => try f.freshAtom(use.key, code.id(), f.m.isDraft(lc), ls.a, ls.e != 0, use.site.inst, &f.atoms),
        .outside => try f.atoms.append(f.gpa, outside_atom),
        .twice => st.twice = true,
        .answer => {
            // The answer of a function that the known function captured:
            // that function is in a location of this one.
            if (ls.a < code.own_params or ls.a - code.own_params >= code.ncaps or ls.a >= lc.arity) {
                try f.lostAnswer(use, st);
                continue;
            }
            const lf = lc.fns[ls.a] orelse {
                try f.lostAnswer(use, st);
                continue;
            };
            const inner = try f.innerUse(code, ls.a, lf, use);
            const outer = st.suffix;
            const outer_whole = st.whole;
            st.suffix = &.{};
            st.whole = true;
            try f.answerOf(try f.capVal(code, ls.a - code.own_params), &inner, ls.e, st, depth + 1);
            st.suffix = outer;
            st.whole = outer_whole;
        },
        .param => {
            if (ls.a >= code.own_params) {
                // A captured value in the answer: each run answers the
                // same cell, so two runs can answer one cell. The answer holds it.
                st.twice = true;
                if (ls.a - code.own_params < code.ncaps) {
                    _ = try f.argLeaves(try f.capVal(code, ls.a - code.own_params), lc.layouts[ls.a], ls.e, &.{}, false, &f.atoms);
                } else try f.lostAnswer(use, st);
                continue;
            }
            // What the holder hands that parameter.
            var slots: std.ArrayList(Slot) = .empty;
            defer slots.deinit(f.gpa);
            // The answer entry is at the result entry's location, or
            // below it: the parameter's cells at the same place.
            var rel: ?[]const u64 = null;
            const kloc = m.loc.layoutEntries(lc.layouts[lc.arity])[k].loc;
            if (ae) |ae_| {
                const aloc = m.loc.layoutEntries(fnc.layouts[fnc.arity])[ae_].loc;
                if (cv < Loc.all and m.loc.isPrefix(kloc, aloc)) {
                    try f.suffixOf(aloc, kloc, psuffix);
                    rel = try f.gpa.dupe(u64, psuffix.items);
                }
            }
            if (!try f.slotsOf(use, ls.a, lc.layouts[ls.a], ls.e, rel, &slots)) {
                try f.lostAnswer(use, st);
                continue;
            }
            var sink: FlatSink = .{ .st = st, .depth = depth };
            const wide = m.loc.layoutEntries(lc.layouts[ls.a])[ls.e].kind.wide();
            for (slots.items) |slot| {
                // The holder can hand one cell to two calls: two answers can be that cell.
                if (!slot.free) st.twice = true;
                // The part of what is handed that the function's parameter entry is.
                const part = try f.partBelow(lc.layouts[ls.a], ls.e, fnc.layouts[ls.a], slot.fe, &.{}, psuffix);
                for (slot.srcs) |ss| try f.resolve(use, ss, part, wide, &sink, 0);
            }
        },
    };
}

/// Each cell that the answer of the function value `v`, in the location of `use`, can hold escapes at the use's site.
fn escapeAnswer(f: *Frame, v: Val, use: *const Use) Error!void {
    const n = f.m.loc.layouts.items[use.fnc.layouts[use.fnc.arity]].len;
    const start: u32 = @intCast(f.atoms.items.len);
    // Each entry is its own query: the answers in work (`SrcState.seen`) of
    // one entry are not those of another, and a set shared by every entry
    // of a wide answer filled up and read the answer as lost (every
    // argument in sight), though no answer came back to itself.
    for (0..n) |ae| {
        var st: SrcState = .{ .inst = use.site.inst, .whole = true };
        try f.answerOf(v, use, @intCast(ae), &st, 0);
    }
    try f.noteEscape(start, use.site.inst);
}

/// Each value that `use` hands the function escapes: the function can keep it.
fn escapeSupplies(f: *Frame, use: *const Use) Error!void {
    if (use.kind == .top) return;
    var sink: EscSink = .{ .inst = use.site.inst };
    for (use.fnc.supply) |srcs| for (srcs) |s| try f.resolve(use, s, &.{}, false, &sink, 0);
}

// ---- the frame's own function parameters ---------------------------------------------------

/// The draft of the function at root `root`, made from its type on first use.
fn draftOf(f: *Frame, root: u32, callee_inst: ?u32) Error!u32 {
    const m = f.m;
    for (f.drafts.items, 0..) |dr, i| if (dr.root == root) return @intCast(i);
    const r = f.roots.items[root];
    var fnt = if (callee_inst) |ci| m.fnType(m.typeOfInst(ci)) else null;
    if (fnt == null and r.index < f.param_ty.items.len) fnt = m.fnType(f.param_ty.items[r.index]);
    const ft = fnt orelse {
        // No function type to read: nothing is known of what the function is handed.
        const places = try f.gpa.alloc(PlaceId, 1);
        places[0] = m.var_place;
        const layouts = try m.arena.alloc(u32, 1);
        layouts[0] = try m.loc.layoutOf(m.var_place);
        const off = try m.arena.alloc(u32, 1);
        off[0] = 0;
        try f.drafts.append(f.gpa, .{ .root = root, .arity = 0, .places = places, .layouts = layouts, .off = off, .supply = &.{}, .free = &.{}, .lost = true });
        return @intCast(f.drafts.items.len - 1);
    };
    const pvars = m.in.store.vars(ft.params);
    const arity: u32 = @intCast(pvars.len);
    const places = try f.gpa.alloc(PlaceId, arity + 1);
    const layouts = try m.arena.alloc(u32, arity + 1);
    const off = try m.arena.alloc(u32, arity + 1);
    var total: u32 = 0;
    for (pvars, 0..) |pv, k| {
        places[k] = try m.placeOf(pv.toOptional());
        layouts[k] = try m.loc.layoutOf(places[k]);
        off[k] = total;
        total += @intCast(m.loc.layouts.items[layouts[k]].len);
    }
    off[arity] = total;
    places[arity] = try m.placeOf(ft.result.toOptional());
    layouts[arity] = try m.loc.layoutOf(places[arity]);
    const supply = try f.gpa.alloc(std.ArrayList(Src), total);
    for (supply) |*s| s.* = .empty;
    const free = try f.gpa.alloc(bool, total);
    @memset(free, true);
    try f.drafts.append(f.gpa, .{ .root = root, .arity = arity, .places = places, .layouts = layouts, .off = off, .supply = supply, .free = free });
    return @intCast(f.drafts.items.len - 1);
}

/// The answer of the function at draft `di` in the call `inst`: its index in `answers`.
fn answerRoot(f: *Frame, di: u32, inst: u32) Error!u32 {
    for (f.answers.items, 0..) |a, i| if (a.di == di and a.inst == inst) return @intCast(i);
    const place = f.drafts.items[di].places[f.drafts.items[di].arity];
    const root = try f.newRoot(.answer, place, inst);
    f.roots.items[root].index = di;
    f.roots.items[root].ent = @intCast(f.answers.items.len);
    try f.answers.append(f.gpa, .{ .di = di, .inst = inst, .root = root });
    return @intCast(f.answers.items.len - 1);
}

/// The frame hands the atoms `f.atoms[w..]` to the function at draft `di`,
/// slot `slot`: the sources, and whether the function could write there.
fn supplyAtoms(f: *Frame, di: u32, slot: u32, w: u32, point: u32, others: []const Other, arg: usize, se: u32, dup: bool) Error!void {
    return f.supplyAtomsSend(di, slot, w, point, others, arg, se, dup, none, none);
}

fn supplyAtomsSend(f: *Frame, di: u32, slot: u32, w: u32, point: u32, others: []const Other, arg: usize, se: u32, dup: bool, send_callee: u32, send_base: u32) Error!void {
    const end = f.atoms.items.len;
    if (end == w) return;
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    f.newVisit();
    for (w..end) |i| try f.atomSrcsIn(f.atoms.items[i], &srcs);
    try f.drafts.items[di].supply[slot].appendSlice(f.gpa, srcs.items);
    const ai = try f.answerRoot(di, point);
    for (w..end) |i| try f.answers.items[ai].base.append(f.gpa, f.atoms.items[i]);
    if (dup) f.drafts.items[di].free[slot] = false;
    // Could the function write here: the check of a write, with no line.
    try f.demand(w, .{ .point = point, .op = .supply, .kind = if (send_callee != none) .send else .writer, .callee_inst = send_callee, .base_inst = send_base, .others = others, .arg = arg, .se = se, .draft = di, .slot = slot, .skip = f.answers.items[ai].root, .send = send_callee != none, .dup = dup and send_callee != none });
}

/// No rule follows what the function at draft `di` is handed at `slot` in the
/// call `point`: no claim, and it can be a cell of each value in sight of
/// `use`. So the function's answer can hold them, and the contract says so.
fn supplyLost(f: *Frame, di: u32, slot: u32, point: u32, use: *const Use) Error!void {
    try f.drafts.items[di].supply[slot].append(f.gpa, Src.outside);
    f.drafts.items[di].free[slot] = false;
    const w = f.atoms.items.len;
    var u: ?*const Use = use;
    while (u) |x| : (u = f.upOf(x)) for (x.args) |v| {
        _ = try f.allLeaves(v, &f.atoms);
    };
    try f.uniqueTail(&f.atoms, w);
    const end = f.atoms.items.len;
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    for (w..end) |i| try f.atomSrcs(f.atoms.items[i], &srcs);
    try f.drafts.items[di].supply[slot].appendSlice(f.gpa, srcs.items);
    const ai = try f.answerRoot(di, point);
    try f.answers.items[ai].base.appendSlice(f.gpa, f.atoms.items[w..end]);
    f.atoms.shrinkRetainingCapacity(w);
}

/// A message's entries split by its own type (kernel §11): its field slots
/// (`slots`) and every other entry (`lists`), at `place`, when the send's
/// parameter at entry `e` of `pplace` is one type variable. Null where the
/// message has no slot or cannot be split: the send asks for all of it.
const SendSplit = struct { place: PlaceId, lists: []const u32, slots: []const u32 };

fn sendSlots(f: *Frame, v: Val, pplace: PlaceId, e: u32) Error!?SendSplit {
    const m = f.m;
    if (e != 0 or try f.layoutLen(pplace) != 1) return null;
    const place = f.placeOfVal(v) orelse return null;
    const es = m.loc.layoutEntries(try m.loc.layoutOf(place));
    // The scan of the layout is work (kernel §8).
    _ = f.charge(Loc.scanUnits(es.len));
    var lists: std.ArrayList(u32) = .empty;
    var slots: std.ArrayList(u32) = .empty;
    for (es, 0..) |x, k| try (if (x.kind == .field) &slots else &lists).append(m.arena, @intCast(k));
    if (slots.items.len == 0) return null;
    // A value the walk cannot follow cannot be split: it is handed on whole
    // only when its type holds nothing but slots.
    if (whole(f.nodes.items[v].tag) and lists.items.len != 0) return null;
    return .{ .place = place, .lists = lists.items, .slots = slots.items };
}

/// A call of the frame's own function parameter at root `root`.
fn callParam(f: *Frame, inst: u32, callee: u32, root: u32, vals: []const Val, arg_insts: []const Inst.Index) Error!Val {
    const m = f.m;
    const di = try f.draftOf(root, callee);
    f.drafts.items[di].used = true;
    if (f.drafts.items[di].arity != vals.len) {
        f.drafts.items[di].lost = true;
        for (vals) |v| try f.escape(v, inst);
        return f.unknownResult(inst, vals);
    }
    f.drafts.items[di].called = true;
    // A function the frame does not know can keep a handle, or store into
    // it, at any time (kernel §13).
    for (vals) |v| try f.shareVal(v, inst);
    // The runtime's `send` (the word `sender` on the platform's alias): the
    // message is given up, so each cell of it must be the sender's own.
    const r0 = f.roots.items[root];
    const sender = r0.index < f.param_ty.items.len and m.isSender(f.param_ty.items[r0.index]);
    const before_demands = f.demands.items.len;
    // The demands of slots handed on: a message that only they are in is a send of no cell asked for.
    var slot_demands: usize = 0;
    for (vals, 0..) |v, k| {
        const layout = f.drafts.items[di].layouts[k];
        const n = m.loc.layouts.items[layout].len;
        // The other operands: every other argument.
        const rest = try f.gpa.alloc(Other, vals.len - 1);
        var ri: usize = 0;
        for (vals, 0..) |o, ok| if (ok != k) {
            rest[ri] = .{ .v = o };
            ri += 1;
        };
        for (0..n) |e| {
            const slot = f.drafts.items[di].off[k] + @as(u32, @intCast(e));
            // A send asks for the cells that a write can edit: a list, or what a type variable stands for.
            const ek = m.loc.layoutEntries(layout)[e].kind;
            const asks = sender and (ek == .list or ek == .@"var");
            const base_inst = if (asks and k < arg_insts.len) arg_insts[k].int() else none;
            // A record's field slots in a message are handed on, not asked
            // for (kernel §11): `update` never writes a message, and a write
            // of them after the send is a write of what the runtime holds
            // (`Fn.rewrites`). The message's own type says which cells are
            // slots.
            if (asks and ek == .@"var") if (try f.sendSlots(v, f.drafts.items[di].places[k], @intCast(e))) |split| {
                const w: u32 = @intCast(f.atoms.items.len);
                if (split.lists.len != 0) {
                    const dup = try f.leavesSet(v, split.place, split.lists, &f.atoms);
                    try f.supplyAtomsSend(di, slot, w, inst, rest, std.math.maxInt(usize), none, dup, callee, base_inst);
                }
                const d0 = f.demands.items.len;
                const w2: u32 = @intCast(f.atoms.items.len);
                const dup2 = try f.leavesSet(v, split.place, split.slots, &f.atoms);
                try f.supplyAtomsSend(di, slot, w2, inst, rest, std.math.maxInt(usize), none, dup2 and !m.loc.layoutEntries(layout)[e].single, none, none);
                slot_demands += f.demands.items.len - d0;
                continue;
            };
            const w: u32 = @intCast(f.atoms.items.len);
            const dup = try f.leavesAs(v, f.drafts.items[di].places[k], @intCast(e), &f.atoms);
            const d1 = f.demands.items.len;
            try f.supplyAtomsSend(di, slot, w, inst, rest, std.math.maxInt(usize), none, dup and !m.loc.layoutEntries(layout)[e].single, if (asks) callee else none, base_inst);
            if (ek == .field) slot_demands += f.demands.items.len - d1;
        }
    }
    // A message of no cell asked for is a send too: its line says so.
    if (sender and f.demands.items.len - slot_demands == before_demands) {
        try f.demand(@intCast(f.atoms.items.len), .{ .point = inst, .op = .supply, .kind = .send, .callee_inst = callee, .base_inst = if (arg_insts.len != 0) arg_insts[0].int() else none, .send = true });
    }
    // The function reads what it is handed, and its own cells can be in its answer.
    for (vals) |v| try f.readAll(v, inst);
    const ai = try f.answerRoot(di, inst);
    try f.answers.items[ai].base.append(f.gpa, .{ .root = root, .path = f.roots.items[root].path, .e = 0 });
    return f.rootVal(f.answers.items[ai].root);
}

// ---- constructions -------------------------------------------------------------------------

/// The atoms of the list `v`'s own storage, appended to `f.atoms`.
fn selfAtoms(f: *Frame, v: Val) Error!void {
    const m = f.m;
    const place = f.placeOfVal(v) orelse {
        if (v == v_outside) try f.atoms.append(f.gpa, outside_atom);
        return;
    };
    if (whole(f.nodes.items[v].tag)) {
        _ = try f.leaves(v, 0, &f.atoms);
        return;
    }
    const self = try m.selfLoc(place);
    // The scan of the layout is work (kernel §8).
    _ = f.charge(Loc.scanUnits(try f.layoutLen(place)));
    for (m.loc.layoutEntries(try m.loc.layoutOf(place)), 0..) |be, k| if (be.loc == self) {
        _ = try f.leaves(v, @intCast(k), &f.atoms);
    };
}

/// The storage of the list `v` is read at `point` (a spread copies its elements).
fn readSelf(f: *Frame, v: Val, point: u32) Error!void {
    const m = f.m;
    const place = f.placeOfVal(v) orelse return;
    if (whole(f.nodes.items[v].tag)) return f.readAll(v, point);
    const self = try m.selfLoc(place);
    const start: u32 = @intCast(f.lists.items.len);
    // The scan of the layout is work (kernel §8).
    _ = f.charge(Loc.scanUnits(try f.layoutLen(place)));
    for (m.loc.layoutEntries(try m.loc.layoutOf(place)), 0..) |be, k| if (be.loc == self) try f.lists.append(f.gpa, @intCast(k));
    const nmask: u32 = @intCast(f.lists.items.len - start);
    if (nmask == 0) return;
    try f.uses.append(f.gpa, .{ .point = point, .at = f.timeOf(point), .val = try f.cellsNowIn(v), .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = false });
}

/// Whether the value `v` of `inst` is an object that this instruction made
/// (`makesObject`), or a list that a call answers and made: its storage is
/// the frame's own cell, or cells the callee made and nothing else.
fn newItem(f: *Frame, inst: u32, v: Val) Error!bool {
    const m = f.m;
    if (try f.makesObject(inst)) return true;
    if (v == v_none or v == v_outside) return false;
    const n = f.nodes.items[v];
    if (n.tag != .ref) return false;
    const r = f.roots.items[n.a];
    if (r.kind != .local or r.inst != inst or n.b != r.path) return false;
    const self = try m.selfLoc(r.place);
    // The scan of the layout is work (kernel §8).
    _ = f.charge(Loc.scanUnits(m.loc.layouts.items[r.layout].len));
    for (m.loc.layoutEntries(r.layout), 0..) |e, k| if (e.loc == self) {
        const ent = f.rents.items[r.ent + k];
        switch (ent.kind) {
            .own => return true,
            .derived => return ent.len == 0,
            // A new name of an array that exists.
            .version, .taken => return false,
            .alias => {
                for (f.atoms.items[ent.start..][0..ent.len]) |a| if (f.roots.items[a.root].kind != .fresh) return false;
                return true;
            },
        }
    };
    return false;
}

/// A spread literal `[ a, …xs, b ]`: one construction (ownership-v2.md §2.13.2).
fn spreadChain(f: *Frame, inst: u32, sp: Bir.Spread) Error!Val {
    const m = f.m;
    const items = m.bir.spreadItems(sp);
    f.noteChain(inst, items);
    const place = try m.placeOfInst(inst);
    var elems: std.ArrayList(Val) = .empty;
    defer elems.deinit(f.gpa);
    var spreads: std.ArrayList(Val) = .empty;
    defer spreads.deinit(f.gpa);
    var others: std.ArrayList(Other) = .empty;
    defer others.deinit(f.gpa);
    var first: usize = items.len;
    for (items, 0..) |it, k| {
        const v = try f.ev(it[0]);
        if (it[1] == 1) {
            if (first == items.len) first = k;
            try spreads.append(f.gpa, v);
            try others.append(f.gpa, .{ .v = v, .self_only = true });
        } else {
            try elems.append(f.gpa, v);
            try others.append(f.gpa, .{ .v = v_none });
        }
    }
    // No spread: a literal. The first spread last: a prepend. It copies, or
    // it answers the array that the spread is a view of (`listOf`'s `front`).
    const has_base = first != items.len and first + 1 != items.len;
    const bv: Val = if (has_base) others.items[first].v else v_none;
    if (bv != v_none) {
        // The first spread is the base: its storage takes the other items.
        const w: u32 = @intCast(f.atoms.items.len);
        try f.selfAtoms(bv);
        const os = try f.gpa.dupe(Other, others.items);
        os[first].v = v_none;
        try f.demand(w, .{ .point = inst, .op = .construction, .kind = .construction, .base_inst = items[first][0], .others = os });
    }
    // Each spread's storage is read here; the base's too: a write of a list is a use of it.
    for (others.items) |o| if (o.self_only) try f.readSelf(o.v, inst);
    // One spread, and it is last: a prepend. `List.cons` answers the spread's
    // base array when the item in front is the element stored before the
    // view. An item that its own instruction made is no element of an array
    // that exists (ownership-v2.md §2.3.4, *When a prepend may re-cons*, rule 2).
    var front: Val = v_none;
    if (first != items.len and first + 1 == items.len) {
        var ei: usize = 0;
        for (items) |it| if (it[1] != 1) {
            if (!try f.newItem(it[0], elems.items[ei])) front = others.items[first].v;
            ei += 1;
        };
    }
    return f.listOf(place, inst, elems.items, spreads.items, bv, front);
}

/// `a ++ b ++ c` on lists: one construction whose base is `a`.
fn appendChain(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const place = try m.placeOfInst(inst);
    var insts: std.ArrayList(u32) = .empty;
    defer insts.deinit(f.gpa);
    var at = inst;
    while (true) {
        f.noteWalked(at);
        f.noteWalked(m.datas[at].lhs);
        const args = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(m.datas[at].rhs)), Inst.Index);
        try insts.append(f.gpa, args[0].int());
        const right = args[1].int();
        if (m.tags[right] == .call and m.isListAppend(right) and m.bir.extraSlice(m.bir.subRange(@fromBackingInt(m.datas[right].rhs)), Inst.Index).len == 2 and m.spreadOf(f.d, right) == null) {
            at = right;
            continue;
        }
        try insts.append(f.gpa, right);
        break;
    }
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    for (insts.items) |i| try vals.append(f.gpa, try f.ev(i));
    const bv = vals.items[0];
    if (bv != v_none) {
        const w: u32 = @intCast(f.atoms.items.len);
        try f.selfAtoms(bv);
        const os = try f.gpa.alloc(Other, vals.items.len);
        for (os, vals.items, 0..) |*o, v, k| o.* = .{ .v = if (k == 0) v_none else v, .self_only = true };
        try f.demand(w, .{ .point = inst, .op = .append, .kind = .append, .base_inst = insts.items[0], .others = os });
    }
    // Each operand's storage is read here; the base's too: a write of a list is a use of it.
    for (vals.items) |v| try f.readSelf(v, inst);
    return f.listOf(place, inst, &.{}, vals.items, bv, v_none);
}

// ---- the program entry ---------------------------------------------------------------------

/// `Tea.application { init, update, view, … }` (research report 110 §6.6):
/// the runtime hands `update` a model that is `own` where `init` and `update`
/// answer it `own` and no other function of the record keeps it.
/// The functions that a value of a field of an entry's record can be: each
/// value of a join, each a known function. False where one has no known
/// code: no contract says what it does.
fn fnMembers(f: *Frame, v: Val, out: *std.ArrayList(Code)) Error!bool {
    if (v == v_none) return false;
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        // Each arm is work (kernel §8); past the budget the members are not known.
        if (f.charge(n.b)) return false;
        for (0..n.b) |ki| if (!try f.fnMembers(f.lists.items[n.a + 2 * ki], out)) return false;
        return true;
    }
    const code = (try f.codeOf(v)) orelse return false;
    try out.append(f.gpa, code);
    return true;
}

fn entryCall(f: *Frame, inst: u32, entry: [2]u32, arg: u32) Error!Val {
    const m = f.m;
    // Kernel §6.13. Every function of the record is accounted for by a
    // contract: each value it can be is a known function (`fnMembers`), or
    // the field has no fact, and no location of the model is `own`. Where
    // each function has the model is read off the entry's declared type
    // (`Mod.entryShape`), never guessed from locations: a field whose answer
    // has the model is a producer of it, at the answer itself or at one item
    // of a tuple (`model × Cmd msg`); the model is the type variable of
    // `update`'s last parameter.
    const Field = struct { shape: Mod.EntryField, ty: Var.Optional, from: usize, len: usize, view: bool };
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(f.gpa);
    var codes: std.ArrayList(Code) = .empty;
    defer codes.deinit(f.gpa);
    // No fact for some function of the record, or for where the model is.
    var no_fact = false;
    const shape = try m.entryShape(entry);
    if (shape == null) no_fact = true;
    // The program's value holds the record: what the runtime was handed.
    var held: std.ArrayList(Val) = .empty;
    defer held.deinit(f.gpa);
    if (m.tags[arg] == .record) {
        for (m.bir.extraSlice(Bir.inlineRange(m.datas[arg]), Bir.Field)) |fd| {
            const v = try f.eval(fd.value.int(), .fn_arg, false);
            try held.append(f.gpa, v);
            // The runtime keeps the record: what a function of it captured is read at any time.
            try f.escape(v, inst);
            const sym = m.bir.symbol(fd.name);
            var sf: ?Mod.EntryField = null;
            if (shape) |sh| for (sh) |x| if (x.name == sym) {
                sf = x;
            };
            const s = sf orelse {
                // A field that the entry's type does not name: no row describes it.
                no_fact = true;
                try f.flowTop(v, inst);
                continue;
            };
            if (s.unknown) no_fact = true;
            if (!s.is_fn) continue;
            const from = codes.items.len;
            // A constructor whose answer holds no cell is the value of no
            // object (`ctorValue`): it keeps and writes nothing. Any other
            // function value of no object is one that no rule names (a
            // field of a top-level record), and has no known code.
            const ctor = m.tags[fd.value.int()] == .ctor or m.tags[fd.value.int()] == .ext_ctor;
            var known = if (v == v_none) ctor else try f.fnMembers(v, &codes);
            if (known) for (codes.items[from..]) |c| if (c.own_params != s.arity) {
                known = false;
            };
            if (!known) {
                // A function with no known code: the default. It can write
                // nothing (`flowTop` refuses that), and it can keep each
                // value that the runtime hands it, the model among them.
                codes.shrinkRetainingCapacity(from);
                no_fact = true;
                try f.flowTop(v, inst);
                continue;
            }
            // The rows below judge what each function does with its own
            // parameters. No row describes what the runtime hands on to a
            // function that it captured: those are in the default.
            for (codes.items[from..]) |c| {
                const site: Site = .{ .inst = inst };
                const top: Use = .{ .kind = .top, .id = f.useId(), .key = inst, .site = &site, .code = c };
                try f.flowCaptures(c, &top);
                // What the runtime hands a function parameter is the default (kernel §6.8).
                try f.defaultParams(c, &top);
            }
            const ty = m.typeOfInst(fd.value.int());
            const view = if (m.fnType(ty)) |ft| try m.isView(ft.result.toOptional(), 0) else false;
            try fields.append(f.gpa, .{ .shape = s, .ty = ty, .from = from, .len = codes.items.len - from, .view = view });
        }
    } else {
        const v = try f.ev(arg);
        try held.append(f.gpa, v);
        try f.escape(v, inst);
        no_fact = true;
    }
    // The model: the type of the model parameter of a field that has one
    // (`update`). Its layout names the locations judged below.
    var model_ty: Var.Optional = .none;
    // A producer handed no model (`init`): the first model comes from it.
    var has_first = false;
    for (fields.items) |fd| {
        if (fd.shape.model_param != none and model_ty == .none) if (m.fnType(fd.ty)) |ft| {
            const pv = m.in.store.vars(ft.params);
            if (fd.shape.model_param < pv.len) model_ty = pv[fd.shape.model_param].toOptional();
        };
        if (fd.shape.answer != .none and fd.shape.model_param == none) has_first = true;
    }
    // A function that is not handed the model and writes a parameter: the
    // runtime hands it a value that the function does not own.
    const init_sym: ?InternPool.Symbol = if (m.in.interner) |i| i.find("init") else null;
    for (fields.items) |fd| {
        if (fd.shape.model_param != none and fd.shape.answer != .none) continue;
        for (codes.items[fd.from..][0..fd.len]) |c| if (f.writesOwn(c.contract, c.own_params)) {
            const is_init = init_sym != null and init_sym.? == fd.shape.name;
            try m.addRefusal(f, inst, .unknown, if (is_init) "the runtime calls `init` with a value that the function does not own" else "the runtime calls this function with a value that the function does not own");
        };
    }
    if (model_ty == .none) {
        for (fields.items) |fd| if (fd.shape.model_param != none) for (codes.items[fd.from..][0..fd.len]) |c| if (f.writesOwn(c.contract, c.own_params)) {
            try m.addRefusal(f, inst, .unknown, "the record has no `update`");
        };
        return f.unknownResult(inst, held.items);
    }
    const ml = try m.loc.layoutOf(try m.placeOf(model_ty));
    const mes = m.loc.layoutEntries(ml);
    const own = try f.gpa.alloc(bool, mes.len);
    defer f.gpa.free(own);
    // With no producer handed no model, the runtime makes the first one, and
    // no fact names its holder.
    @memset(own, !no_fact and has_first);
    // Every comparison below of a model location with a location of a
    // function's contract goes through the call map (`locsMeet`): the
    // contract's layouts are those of the function's own type, which can be
    // wider than the model's (`{ r | n : Int }`, a type variable), and a pair
    // that the map cannot decide counts as one cell (kernel §4.1, §6.13;
    // report 124 §4 F1).
    //
    // Kernel §6.13. A model location is `own` for `update` only where a
    // positive fact names its one holder, the model, in every producer of
    // the model (each function whose answer has it: `init`, `update`,
    // `settle`): each source of it there is a cell the producer made and let
    // go nowhere (`freshOwn`), or a model location of the producer's own
    // parameter that is `own` in its turn, that it let go nowhere and
    // answers at no other place (`paramOwn`). Every other source has another
    // holder or no fact: a top-level value (`outside`), the answer of a
    // function, a capture (the record holds it for ever), the message (the
    // runtime can hand one message twice: a handler keeps its message until
    // the next render), the `Host`. The sources are those of every entry of
    // the answer that can hold a cell of the location, as at a call
    // (`expandSrcs`): a wide entry holds each cell of the locations below it,
    // so each of its sources is one of the location's. The largest
    // solution: start from `own` everywhere and take away.
    //
    // The facts of each producer are read once (`bad`: a source with another
    // holder or no fact; `deps`: the model locations whose `own` it needs),
    // and the largest solution is then found by taking away along `deps`
    // (a worklist): each fact and each pair of locations once, and each a
    // step of the declaration's budget (kernel §8). Past the budget no
    // location is `own`: the walk gave up, and a give-up accepts nothing.
    const bad = try f.gpa.alloc(bool, mes.len);
    defer f.gpa.free(bad);
    @memset(bad, false);
    // Pairs (k, k2): location k is `own` only when k2 is.
    var deps: std.ArrayList([2]u32) = .empty;
    defer deps.deinit(f.gpa);
    var over = false;
    var ris: std.ArrayList(u32) = .empty;
    defer ris.deinit(f.gpa);
    if (own.len != 0 and own[0]) facts: for (fields.items) |fd| {
        // Where the answer has the model: the answer, or one item of a tuple.
        const at: u32 = switch (fd.shape.answer) {
            .none => continue,
            .whole => 0,
            .index => try m.loc.extend(0, .{ .kind = .index, .payload = @intCast(fd.shape.index), .cyc = false, .head = 0 }),
        };
        const model_param = fd.shape.model_param;
        // The answer's type as the record has it: the model's locations in it.
        const rl: ?u32 = if (m.fnType(fd.ty)) |ft| try m.loc.layoutOf(try m.placeOf(ft.result.toOptional())) else null;
        // The answer layout's entries, sorted by location, for a binary search.
        var rl_at: std.ArrayList([2]u32) = .empty;
        defer rl_at.deinit(f.gpa);
        if (rl) |l| for (m.loc.layoutEntries(l), 0..) |re, i| try rl_at.append(f.gpa, .{ re.loc, @intCast(i) });
        std.mem.sort([2]u32, rl_at.items, {}, struct {
            fn lessThan(_: void, x: [2]u32, y: [2]u32) bool {
                return x[0] < y[0];
            }
        }.lessThan);
        for (codes.items[fd.from..][0..fd.len]) |code| {
            const c = code.contract;
            // Per entry of the model parameter: the model locations it meets, once.
            const pe_len: usize = if (model_param != none and model_param < c.arity) m.loc.layoutEntries(c.layouts[model_param]).len else 0;
            const meets = try f.gpa.alloc(?[]const u32, pe_len);
            defer f.gpa.free(meets);
            @memset(meets, null);
            for (mes, 0..) |me, k| {
                if (bad[k]) continue;
                const want = if (at == 0) me.loc else try m.loc.concat(at, me.loc);
                // The model location's entry in the answer's layout; none: no fact.
                const wi: u32 = entryAt(rl_at.items, want);
                if (wi == none) {
                    bad[k] = true;
                    continue;
                }
                // The entries of the contract's answer that meet it (`locsMeet`).
                if (!try f.meetsOf(rl.?, wi, c.layouts[c.arity], &ris)) {
                    over = true;
                    break :facts;
                }
                for (ris.items) |ri| {
                    for (c.res[ri]) |s| switch (s.kind) {
                        .fresh => if (!freshOwn(m, c, ri, s)) {
                            bad[k] = true;
                        },
                        .param => {
                            if (s.a != model_param or !paramOwn(c, ri, s)) {
                                bad[k] = true;
                                continue;
                            }
                            // From model locations: `own` only when each of them is.
                            if (meets[s.e] == null) {
                                var ks: std.ArrayList(u32) = .empty;
                                if (!try f.meetsOf(c.layouts[model_param], s.e, ml, &ks)) {
                                    over = true;
                                    break :facts;
                                }
                                meets[s.e] = ks.items;
                            }
                            const ks = meets[s.e].?;
                            if (ks.len == 0) bad[k] = true;
                            for (ks) |k2| try deps.append(f.gpa, .{ @intCast(k), k2 });
                        },
                        .outside, .answer, .twice => bad[k] = true,
                    };
                }
            }
        }
    };
    // What the other functions keep of the model is not `own`: the runtime
    // holds their answers. This is decided before the taking away below, so
    // that each location that needs a kept one is taken away with it (a
    // location `update` answers from a kept one: research report 159's
    // second review, `{ m | w2 = m.w }` with `w` kept by a message `view`
    // builds). A `view`'s answer is markup, and a platform's
    // runtime reads the values of its holes only while it renders it,
    // which it does before it runs `update` again, and keeps none of their
    // lists past that (`boundary.md` §9.4.8, kernel §6.12): so what a
    // `view` answers is no holder of the model here. What it lets escape
    // (a message built in a hole, a function that answers one), and what it
    // hands a function (which can keep it), still is.
    for (fields.items) |fd| {
        if (fd.shape.answer != .none) continue;
        for (codes.items[fd.from..][0..fd.len]) |c0| {
            const c = c0.contract;
            // The parameter locations that the answer holds, once.
            const answered = try f.gpa.alloc(bool, c.flags.len);
            defer f.gpa.free(answered);
            @memset(answered, false);
            if (!fd.view) for (c.res) |rs| for (rs) |s| if (s.kind == .param and s.a < c.arity and c.off[s.a] + s.e < c.off[s.a + 1]) {
                answered[c.off[s.a] + s.e] = true;
            };
            for (0..c0.own_params) |pj| {
                // The runtime hands the model at the model parameter only (the
                // entry's declared type, `Mod.entryShape`): any other parameter of
                // a consumer is a value the runtime made (a `Url`, an event), which
                // holds no cell of the model. Its locations name another type, and
                // the call map cannot compare them with the model's (kernel §11).
                if (pj != fd.shape.model_param) continue;
                const pes = m.loc.layoutEntries(c.layouts[pj]);
                for (0..pes.len) |e| {
                    var kept = c.flags[c.off[pj] + e] & (flag_w | flag_e) != 0;
                    if (answered[c.off[pj] + e]) kept = true;
                    if (handsOn(c, @intCast(pj), @intCast(e))) kept = true;
                    if (!kept) continue;
                    // Past the budget no location is `own` (kernel §8).
                    if (!try f.meetsOf(c.layouts[pj], @intCast(e), ml, &ris)) {
                        @memset(own, false);
                        continue;
                    }
                    for (ris.items) |k| own[k] = false;
                }
            }
        }
    }
    if (over) {
        @memset(own, false);
    } else {
        // Take away: a location that is not `own` takes away each location that needs it.
        const needed_by = try f.gpa.alloc(std.ArrayList(u32), mes.len);
        defer f.gpa.free(needed_by);
        @memset(needed_by, .empty);
        for (deps.items) |p| try needed_by[p[1]].append(f.gpa, p[0]);
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(f.gpa);
        for (own, bad, 0..) |*o, b, k| if (b or !o.*) {
            o.* = false;
            try work.append(f.gpa, @intCast(k));
        };
        take: while (work.pop()) |k2| for (needed_by[k2].items) |k| {
            if (f.tick()) {
                @memset(own, false);
                break :take;
            }
            if (!own[k]) continue;
            own[k] = false;
            try work.append(f.gpa, k);
        };
    }
    // The verdicts: one for each location that a producer handed the model
    // (`update`, `settle`) writes. A write is `own` only where each model
    // location it can write is.
    // The message is never `own`: no fact names its one holder. A handler
    // of the rendered markup keeps its message until the next render and can
    // send it twice, and a message can hold a top-level value or anything a
    // platform's runtime made; a `send` is checked where it is written, but
    // it is one source among these (kernel §6.13).
    for (fields.items) |fd| {
        if (fd.shape.model_param == none or fd.shape.answer == .none) continue;
        for (codes.items[fd.from..][0..fd.len]) |c0| {
            const c = c0.contract;
            for (0..c0.own_params) |pj| {
                const pes = m.loc.layoutEntries(c.layouts[pj]);
                for (pes, 0..) |pe, e| {
                    if (c.flags[c.off[pj] + e] & flag_w == 0) continue;
                    var ok = false;
                    // Past the budget, or where the walk gave up, the write is refused (kernel §3.3, §8).
                    if (pj == fd.shape.model_param and try f.meetsOf(c.layouts[pj], @intCast(e), ml, &ris)) {
                        ok = ris.items.len != 0 and !f.failed and !m.steps_over;
                        for (ris.items) |k| if (!own[k]) {
                            ok = false;
                        };
                    }
                    try m.addEntryLine(f, inst, c0, pj == fd.shape.model_param, pe.loc, ok);
                }
            }
        }
    }
    return f.unknownResult(inst, held.items);
}

/// The index that `want` has in `sorted` (pairs of a location and an index, by location), or `none`.
fn entryAt(sorted: []const [2]u32, want: u32) u32 {
    var lo: usize = 0;
    var hi = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid][0] < want) lo = mid + 1 else hi = mid;
    }
    return if (lo < sorted.len and sorted[lo][0] == want) sorted[lo][1] else none;
}

/// Whether a top-level value read through the call map `cr` of its
/// contract holds a cell there (`evalInner .top`): an entry with a source,
/// a location no entry covers, or, at `Loc.all`, a location every entry
/// covers where some entry has a source (`every`).
fn topHolds(c: *const Contract, cr: u32, every: bool) bool {
    if (cr == Loc.all) return every;
    return cr == none or c.res[cr].len != 0;
}
