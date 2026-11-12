//! own3, layer 3: one walk of one code (research report 110 §6.3, §6.7;
//! report 111 §2). A code is a declaration's body, a lambda or a local
//! function. The walk goes over the expression tree once, in evaluation
//! order, and gives each expression a **value**:
//!
//! - `none`: no object;
//! - `shared`: an object with no claim (the default);
//! - `ref(root, path)`: a part of a root of this frame;
//! - `built`: a tuple, a record or a constructor application of this frame;
//! - `join`: the value of one of several branches;
//! - `closure`, `fnref`: a function value whose code is known;
//! - `smear`: every cell of some values, at every location;
//! - `unknown`: a value that the walk cannot follow, with no claim: it can
//!   hold every cell of some values, at every location;
//! - `later`: in a closure, a local of this frame that is bound after the
//!   closure is made (`capVal` reads it, and nothing else does).
//!
//! A **root** is a parameter, a captured local, a value that the frame made
//! (a list literal, a call's result) or the answer of a function parameter.
//! An **atom** `(root, path, entry)` names the cells of one location of a
//! root at or below a path. Two atoms can be one cell only when they have one
//! root and one entry, and one path is a prefix of the other.
//!
//! **A write makes a new name.** Where a callee writes a location and
//! answers it, the result's location is a new atom (`taken`), not the old
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
//! **The write rule.** A write is accepted when no target atom is `shared`,
//! a capture or a function parameter's answer, no value that escaped before
//! the write reaches a target, no other operand that the operation reads
//! reaches a target, and no read after the write reaches a target. A
//! forgotten case gives `shared`, which refuses.
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

pub const Val = u32;
pub const v_none: Val = 0;
pub const v_shared: Val = 1;

const Tag = enum(u8) { none, shared, ref, built, join, closure, smear, fnref, unknown, later };
const Node = struct { tag: Tag, place: PlaceId = @fromBackingInt(0), a: u32 = 0, b: u32 = 0 };
const Kid = struct { step: u32, val: Val };
/// `via`: the root that the frame made through which this cell was read
/// (a call's result that holds cells of its arguments), or `none`.
///
/// `dead`: an old name of cells that have a new name since the instruction
/// `dead` (a callee wrote them, or could, and answers them), or `none`. The
/// value that holds the new name is no reader of the old value: a write at
/// that instruction or before does not count it as a holder. The cells are
/// the same: a write after that instruction counts it, and so does an
/// overlap test for one cell at two places.
pub const Atom = struct { root: u32, path: u32, e: u32, via: u32 = none, dead: u32 = none };
const RootKind = enum(u8) { shared, param, capture, local, answer };
const Root = struct {
    kind: RootKind,
    place: PlaceId = @fromBackingInt(0),
    layout: u32 = 0,
    inst: u32 = none,
    /// `param`, `capture`: the contract's parameter. `answer`: the function draft.
    index: u32 = none,
    /// `local`: its entries. `param`, `capture`: its flags in `pflags`.
    ent: u32 = 0,
    /// `local`: a call's result (the ground of a verdict).
    call: bool = false,
    /// `local`: no cell of another root is at two places of this one (the
    /// callee's contract says so, or the frame made it so).
    linear: bool = true,
    path: u32 = 0,
};
/// What a location of a root that the frame made holds: `own` cells of its
/// own; `shared`; `alias`, the cells of other roots and no other; `derived`,
/// cells of other roots in an order of its own (and its own when `fresh`);
/// `version`, the new name of cells that the callee wrote and answers (the
/// old names are in the entry: a write of the new name is a write of them);
/// `taken`, an element that a trusted loop of `core/` took out of its list.
const EKind = enum(u8) { own, shared, alias, derived, taken, version };
const REntry = struct { kind: EKind, start: u32 = 0, len: u32 = 0, fresh: bool = false };
const Read = struct { point: u32, val: Val, ctx: u32, mask: u32 = 0, nmask: u32 = 0, all: bool = true };
const Escape = struct { start: u32, len: u32, point: u32, ctx: u32 };
const Ctx = struct { parent: u32, case: u32, arm: u32, depth: u32 };

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
    c: *const Contract = undefined,
    fnc: *const CMod.Fn = undefined,
    j: u32 = none,
    args: []const Val = &.{},
    own: u32 = 0,
    up: ?*const Use = null,
    site: *const Site,
    depth: u32 = 0,
    /// The function in the location, once `flow` knows which it is: a known
    /// function, or the frame's own function parameter at `root`.
    code: ?Code = null,
    root: u32 = none,

    /// Whether a holder on the way writes a cell after it handed that cell on.
    fn rewrites(use: *const Use) bool {
        var u: ?*const Use = use;
        while (u) |x| : (u = x.up) {
            if (x.kind == .top) return false;
            if (x.fnc.rewrites) return true;
        }
        return false;
    }
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

const Op = enum(u8) { call, construction, append, supply };

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
    /// `supply`: the function is the runtime's `send`: the check has a line.
    send: bool = false,
};

m: *Mod,
gpa: Allocator,
parent: ?*@This(),
id: u32,
decl: u32,
d: Bir.Decl,
is_lambda: bool,
code_inst: u32,
own_params: u32 = 0,
depth: u32 = 0,
failed: bool = false,
/// An answer of the body can be an object that was there before (`Contract.old_result`).
tail_old: bool = false,

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
/// While a write is judged: its instruction (`isOld`).
judge_point: u32 = none,
/// Set by `argLeaves` when the fallback cover gave an entry.
hit_all: bool = false,
uses: std.ArrayList(Read) = .empty,
escapes: std.ArrayList(Escape) = .empty,
demands: std.ArrayList(Demand) = .empty,
ctxs: std.ArrayList(Ctx) = .empty,
cur_ctx: u32 = 0,
returns: std.ArrayList(Val) = .empty,
scratch: std.ArrayList(Atom) = .empty,
/// `uniqueTail`'s own scratch: the indexes of a run, in the order of its atoms.
order: std.ArrayList(u32) = .empty,
/// While a spread literal or a `++` chain is walked: its root call.
chain_root: u32 = none,
/// The next `Use.id`.
next_use: u32 = 1,

const Frame = @This();
pub const Error = Allocator.Error;

pub fn init(m: *Mod, parent: ?*Frame, decl: u32, is_lambda: bool, code_inst: u32) Error!Frame {
    var f: Frame = .{ .m = m, .gpa = m.walk_arena.allocator(), .parent = parent, .id = m.next_frame, .decl = decl, .d = m.bir.decls[decl], .is_lambda = is_lambda, .code_inst = code_inst };
    m.next_frame += 1;
    f.depth = if (parent) |p| p.depth + 1 else 0;
    try f.nodes.append(f.gpa, .{ .tag = .none });
    try f.nodes.append(f.gpa, .{ .tag = .shared });
    try f.roots.append(f.gpa, .{ .kind = .shared });
    try f.ctxs.append(f.gpa, .{ .parent = none, .case = none, .arm = 0, .depth = 0 });
    return f;
}

pub fn addParam(f: *Frame, place: PlaceId, pat: u32, ty: Var.Optional) Error!void {
    const root = try f.newRoot(.param, place, pat);
    f.roots.items[root].index = @intCast(f.params.items.len);
    try f.params.append(f.gpa, root);
    try f.param_ty.append(f.gpa, ty);
    try f.bindPattern(pat, try f.rootVal(root));
}

pub fn walkBody(f: *Frame, body: u32) Error!void {
    try f.returns.append(f.gpa, try f.eval(body, .value, true));
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
    if (f.m.loc.layouts.items[r.layout].len == 0) return v_none;
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

fn smearVal(f: *Frame, place: PlaceId, vs: []const Val) Error!Val {
    var any = false;
    for (vs) |v| if (v != v_none) {
        any = true;
    };
    if (!any) return v_none;
    if (try f.layoutLen(place) == 0) return v_none;
    const start: u32 = @intCast(f.lists.items.len);
    for (vs) |v| if (v != v_none) try f.lists.append(f.gpa, v);
    return f.node(.{ .tag = .smear, .place = place, .a = start, .b = @intCast(f.lists.items.len - start) });
}

fn newRoot(f: *Frame, kind: RootKind, place: PlaceId, inst: u32) Error!u32 {
    const layout = try f.m.loc.layoutOf(place);
    const n = f.m.loc.layouts.items[layout].len;
    var r: Root = .{ .kind = kind, .place = place, .layout = layout, .inst = inst, .path = try f.m.loc.pathRoot(place) };
    switch (kind) {
        .param, .capture => {
            r.ent = @intCast(f.pflags.items.len);
            try f.pflags.appendNTimes(f.gpa, 0, n);
        },
        .local => {
            r.ent = @intCast(f.rents.items.len);
            try f.rents.appendNTimes(f.gpa, .{ .kind = .own }, n);
        },
        .answer, .shared => {},
    }
    try f.roots.append(f.gpa, r);
    return @intCast(f.roots.items.len - 1);
}

const shared_atom: Atom = .{ .root = 0, .path = 0, .e = 0 };

fn overlap(f: *const Frame, a: Atom, b: Atom) bool {
    return a.root == b.root and a.root != 0 and a.e == b.e and f.m.loc.comparable(a.path, b.path);
}

fn overlapAny(f: *const Frame, xs: []const Atom, ys: []const Atom) bool {
    for (xs) |x| for (ys) |y| if (f.overlap(x, y)) return true;
    return false;
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
        for (ys) |y| {
            if (!f.overlap(x, y)) continue;
            if (x.via != none and x.via == y.via and f.roots.items[x.via].linear) continue;
            return true;
        }
    }
    return false;
}

/// Append `f.atoms[start..][0..len]` to `out`, which can be `f.atoms` itself, as cells read through root `via`.
fn copyAtoms(f: *Frame, start: u32, len: u32, via: u32, out: *std.ArrayList(Atom)) Error!void {
    try out.ensureUnusedCapacity(f.gpa, len);
    for (0..len) |i| {
        var a = f.atoms.items[start + i];
        // The first root that held the cell is the one whose parts tell two readings apart.
        if (via != none and a.via == none) a.via = via;
        out.appendAssumeCapacity(a);
    }
}

fn atomEql(a: Atom, b: Atom) bool {
    return a.root == b.root and a.path == b.path and a.e == b.e and a.via == b.via and a.dead == b.dead;
}

fn atomLess(run: []const Atom, x: u32, y: u32) bool {
    const a = run[x];
    const b = run[y];
    if (a.root != b.root) return a.root < b.root;
    if (a.path != b.path) return a.path < b.path;
    if (a.e != b.e) return a.e < b.e;
    if (a.via != b.via) return a.via < b.via;
    if (a.dead != b.dead) return a.dead < b.dead;
    return x < y;
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
    // The indexes by atom, and by index among equal atoms: the first of each group is the one that stays.
    f.order.clearRetainingCapacity();
    try f.order.ensureTotalCapacity(f.gpa, run.len);
    for (0..run.len) |i| f.order.appendAssumeCapacity(@intCast(i));
    std.mem.sortUnstable(u32, f.order.items, @as([]const Atom, run), atomLess);
    // `via` is free to mark an atom that goes: no atom is read through root 0, the `shared` root.
    const gone: u32 = 0;
    var first = f.order.items[0];
    var any = false;
    for (f.order.items[1..]) |i| {
        if (atomEql(run[i], run[first])) {
            run[i].via = gone;
            any = true;
        } else first = i;
    }
    if (!any) return;
    n = 0;
    for (run) |a| {
        if (a.via == gone) continue;
        run[n] = a;
        n += 1;
    }
    list.shrinkRetainingCapacity(from + n);
}

/// The atoms of root `root` at entry `re` of its layout, at or below `path`.
fn rootLeaves(f: *Frame, root: u32, path: u32, re: u32, out: *std.ArrayList(Atom)) Error!void {
    const r = f.roots.items[root];
    switch (r.kind) {
        .shared => try out.append(f.gpa, shared_atom),
        .param, .capture, .answer => try out.append(f.gpa, .{ .root = root, .path = path, .e = re }),
        .local => {
            const ent = f.rents.items[r.ent + re];
            switch (ent.kind) {
                .own, .taken => try out.append(f.gpa, .{ .root = root, .path = path, .e = re }),
                .version => {
                    // The new name, the old names (`dead`), and what the location holds beside them.
                    try out.append(f.gpa, .{ .root = root, .path = path, .e = re });
                    try f.copyAtoms(ent.start, ent.len, root, out);
                },
                .shared => {
                    // No claim on the location, but what it can hold is still held.
                    try out.append(f.gpa, shared_atom);
                    try f.copyAtoms(ent.start, ent.len, root, out);
                },
                .alias => try f.copyAtoms(ent.start, ent.len, none, out),
                .derived => {
                    try out.append(f.gpa, .{ .root = root, .path = path, .e = re });
                    try f.copyAtoms(ent.start, ent.len, root, out);
                },
            }
        },
    }
}

/// The atoms of `v` at entry `e` of its own place's layout. True when one
/// cell can be there twice (a summary location fed by two parts that overlap).
fn leaves(f: *Frame, v: Val, e: u32, out: *std.ArrayList(Atom)) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .shared => {
            try out.append(f.gpa, shared_atom);
            return false;
        },
        .ref => {
            const re = f.m.loc.paths.items[n.b].to_root[e];
            if (re == none) {
                try out.append(f.gpa, shared_atom);
                return false;
            }
            try f.rootLeaves(n.a, n.b, re, out);
            return false;
        },
        .built => {
            var dup = false;
            const at = out.items.len;
            const single = f.m.loc.layoutEntries(try f.m.loc.layoutOf(n.place))[e].single;
            for (0..n.b) |ki| {
                const k = f.kids.items[n.a + ki];
                if (k.val == v_none) continue;
                const before = out.items.len;
                if (try f.m.loc.proj(n.place, Step.fromWord(k.step))) |pr| {
                    for (pr.downOf(e)) |j| {
                        if (try f.leavesAs(k.val, pr.child, j, out)) dup = true;
                    }
                } else if (try f.allLeaves(k.val, out)) {
                    dup = true;
                }
                if (!single and before > at and f.dupOverlap(out.items[at..before], out.items[before..])) dup = true;
            }
            return dup;
        },
        .join => {
            var dup = false;
            for (0..n.b) |ki| {
                if (!f.armLive(n, ki)) continue;
                if (try f.leavesAs(f.lists.items[n.a + 2 * ki], n.place, e, out)) dup = true;
            }
            return dup;
        },
        .closure => {
            const c = f.codes.items[n.a];
            for (0..c.ncaps) |ki| _ = try f.allLeaves(try f.capVal(c, ki), out);
            return false;
        },
        .smear => {
            for (0..n.b) |ki| _ = try f.allLeaves(f.lists.items[n.a + ki], out);
            return false;
        },
        .unknown => {
            // No claim, and each cell of the values that it can be made of.
            try out.append(f.gpa, shared_atom);
            for (0..n.b) |ki| _ = try f.allLeaves(f.lists.items[n.a + ki], out);
            return false;
        },
        .later => unreachable, // read through `capVal` only
    }
}

fn whole(tag: Tag) bool {
    return switch (tag) {
        .closure, .smear, .unknown => true,
        .none, .shared, .ref, .built, .join, .fnref => false,
        .later => unreachable, // read through `capVal` only
    };
}

/// A value that the walk cannot follow, made of the values `vs`: no claim,
/// and each cell of each of them at each location (research report 112
/// §2.5, the default answer). It is never "holds nothing": a missing fact
/// is the default (§2.2).
fn unknownOf(f: *Frame, place: PlaceId, vs: []const Val) Error!Val {
    if (try f.layoutLen(place) == 0) return v_none;
    const start: u32 = @intCast(f.lists.items.len);
    for (vs) |v| if (v != v_none and v != v_shared) try f.lists.append(f.gpa, v);
    const count: u32 = @intCast(f.lists.items.len - start);
    if (count == 0) return v_shared;
    return f.node(.{ .tag = .unknown, .place = place, .a = start, .b = count });
}

/// `leaves` of `v` seen at entry `e` of `place`'s layout, which can be another reading of `v`'s type.
fn leavesAs(f: *Frame, v: Val, place: PlaceId, e: u32, out: *std.ArrayList(Atom)) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .shared => {
            try out.append(f.gpa, shared_atom);
            return false;
        },
        .closure, .smear, .unknown => return f.leaves(v, 0, out),
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    if (n.place == place) return f.leaves(v, e, out);
    const view = try f.m.loc.layoutOf(place);
    const own = try f.m.loc.layoutOf(n.place);
    if (view == own) return f.leaves(v, e, out);
    const cov = try f.m.loc.cover(view, own);
    var dup = false;
    for (cov, 0..) |c, k| if (Loc.hits(c, e)) {
        if (try f.leaves(v, @intCast(k), out)) dup = true;
    };
    return dup;
}

fn allLeaves(f: *Frame, v: Val, out: *std.ArrayList(Atom)) Error!bool {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .shared => {
            try out.append(f.gpa, shared_atom);
            return false;
        },
        .closure, .smear, .unknown => return f.leaves(v, 0, out),
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
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .shared, .fnref => return false,
        .ref => return f.rootReach(n.a, n.b, w),
        .built => {
            for (0..n.b) |ki| if (try f.reach(f.kids.items[n.a + ki].val, w)) return true;
            return false;
        },
        .join => {
            for (0..n.b) |ki| if (f.armLive(n, ki) and try f.reach(f.lists.items[n.a + 2 * ki], w)) return true;
            return false;
        },
        .smear, .unknown => {
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
    for (w) |x| {
        if (x.root != root) continue;
        if (f.m.loc.pathPrefix(path, x.path)) return true;
        if (f.m.loc.pathPrefix(x.path, path)) {
            // The target's location must be at or below this part.
            for (p.to_root) |re| if (re == x.e) return true;
        }
    }
    switch (r.kind) {
        .local => {
            const len = f.m.loc.layouts.items[r.layout].len;
            for (0..len) |i| {
                const ent = f.rents.items[r.ent + i];
                if (ent.kind == .own or ent.kind == .taken) continue;
                if (f.atomsReach(f.atoms.items[ent.start..][0..ent.len], w)) return true;
            }
        },
        .answer => {
            // What the function was handed can be in its answer.
            if (root != f.skip_answer and f.atomsReach(f.answers.items[r.ent].base.items, w)) return true;
        },
        else => {},
    }
    return false;
}

/// Whether a cell of `xs` can be a cell of `w`: the same cells, or the answer
/// of a function parameter that was handed one.
fn atomsReach(f: *Frame, xs: []const Atom, w: []const Atom) bool {
    for (xs) |x| {
        if (f.isOld(x)) continue;
        for (w) |y| if (f.overlap(x, y)) return true;
        const r = f.roots.items[x.root];
        if (r.kind == .answer and x.root != f.skip_answer) for (f.answers.items[r.ent].base.items) |b| {
            if (f.isOld(b)) continue;
            for (w) |y| if (f.overlap(b, y)) return true;
        };
    }
    return false;
}

/// An old name, for the write in judgement: the holder has the cells under
/// the name that a write at this point or later gave them, so it does not
/// read the value from before the write. A name that was old before the
/// write is the cells themselves: the holder reads what the write changes.
fn isOld(f: *const Frame, x: Atom) bool {
    return x.dead != none and (f.judge_point == none or f.judge_point <= x.dead);
}

fn placeOfVal(f: *Frame, v: Val) ?PlaceId {
    const n = f.nodes.items[v];
    return switch (n.tag) {
        .none, .shared, .fnref => null,
        .ref, .built, .join, .closure, .smear, .unknown => n.place,
        .later => unreachable, // read through `capVal` only
    };
}

/// The part of `v` that step `s` reaches. A part that the walk cannot name
/// is `unknown`: it can hold each cell of `v`.
fn project(f: *Frame, v: Val, s: Step) Error!Val {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none => return v_none,
        // A function has no part; a value with no claim has parts with none.
        .shared, .closure, .fnref => return v_shared,
        .ref => {
            const np = (try f.m.loc.pathExtend(n.b, s)) orelse return f.unknownOf(n.place, &.{v});
            const child = f.m.loc.paths.items[np].place;
            if (try f.layoutLen(child) == 0) return v_none;
            return f.refVal(n.a, np);
        },
        .built => {
            for (0..n.b) |ki| if (f.kids.items[n.a + ki].step == s.word()) return f.kids.items[n.a + ki].val;
            // Another constructor's argument holds nothing here, and so does
            // a field that a record update left out: its part holds no object.
            return if (s.kind == .ctor_arg) v_none else v_shared;
        },
        .join => {
            const pr = (try f.m.loc.proj(n.place, s)) orelse return f.unknownOf(n.place, &.{v});
            var tmp: std.ArrayList(Val) = .empty;
            defer tmp.deinit(f.gpa);
            var ctxs: std.ArrayList(u32) = .empty;
            defer ctxs.deinit(f.gpa);
            for (0..n.b) |i| {
                try tmp.append(f.gpa, try f.project(f.lists.items[n.a + 2 * i], s));
                try ctxs.append(f.gpa, f.lists.items[n.a + 2 * i + 1]);
            }
            return f.joinVal(pr.child, tmp.items, ctxs.items);
        },
        .smear, .unknown => {
            const pr = (try f.m.loc.proj(n.place, s)) orelse return f.unknownOf(n.place, &.{v});
            if (try f.layoutLen(pr.child) == 0) return v_none;
            return f.node(.{ .tag = n.tag, .place = pr.child, .a = n.a, .b = n.b });
        },
        .later => unreachable, // read through `capVal` only
    }
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
    while (cs[a].depth > cs[b].depth) a = cs[a].parent;
    while (cs[b].depth > cs[a].depth) b = cs[b].parent;
    while (a != b) {
        if (cs[a].parent == cs[b].parent) return cs[a].case != cs[b].case;
        a = cs[a].parent;
        b = cs[b].parent;
    }
    return true;
}

/// All of `v` is read at `point`.
fn readAll(f: *Frame, v: Val, point: u32) Error!void {
    if (v == v_none or v == v_shared) return;
    if (f.nodes.items[v].tag == .fnref) return;
    try f.uses.append(f.gpa, .{ .point = point, .val = v, .ctx = f.cur_ctx });
}

/// `v` is read at `point` by a callee whose contract flags are `flags` over the signature layout `sig`.
fn readBy(f: *Frame, v: Val, point: u32, sig: u32, flags: []const u8) Error!void {
    if (v == v_none or v == v_shared) return;
    const n = f.nodes.items[v];
    if (n.tag == .fnref) return;
    if (whole(n.tag)) {
        // A function value: read when the callee reads, calls or keeps it
        // (a contract has the read flag on a function parameter that the body uses).
        var any = false;
        for (flags) |x| if (x != 0) {
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
    for (flags) |x| if (x != 0) {
        any_flag = true;
    };
    for (cov, 0..) |c, k| {
        const read = if (c == none) true else if (c == Loc.all) any_flag else flags[c] != 0;
        if (read) try f.lists.append(f.gpa, @intCast(k)) else all = false;
    }
    const nmask: u32 = @intCast(f.lists.items.len - start);
    if (nmask == 0) return;
    try f.uses.append(f.gpa, .{ .point = point, .val = v, .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = all });
}

fn useReaches(f: *Frame, u: Read, ws: []const Atom) Error!bool {
    if (u.all) return f.reach(u.val, ws);
    for (0..u.nmask) |i| {
        f.scratch.clearRetainingCapacity();
        _ = try f.leaves(u.val, f.lists.items[u.mask + i], &f.scratch);
        if (f.atomsReach(f.scratch.items, ws)) return true;
    }
    return false;
}

fn escape(f: *Frame, v: Val, point: u32) Error!void {
    if (v == v_none or v == v_shared) return;
    try f.readAll(v, point);
    const start: u32 = @intCast(f.atoms.items.len);
    _ = try f.allLeaves(v, &f.atoms);
    try f.noteEscape(start, point);
}

fn noteEscape(f: *Frame, start: u32, point: u32) Error!void {
    try f.uniqueTail(&f.atoms, start);
    const len: u32 = @intCast(f.atoms.items.len - start);
    if (len == 0) return;
    for (start..start + len) |i| f.markAtom(f.atoms.items[i], flag_e, 0);
    try f.escapes.append(f.gpa, .{ .start = start, .len = len, .point = point, .ctx = f.cur_ctx });
}

/// Set `flag` on the parameter location that atom `a` is, or was taken from.
fn markAtom(f: *Frame, a: Atom, flag: u8, depth: u32) void {
    const r = f.roots.items[a.root];
    switch (r.kind) {
        .param, .capture => f.pflags.items[r.ent + a.e] |= flag,
        .local => {
            const ent = f.rents.items[r.ent + a.e];
            if ((ent.kind != .taken and ent.kind != .version) or depth > 8) return;
            for (0..ent.len) |i| f.markAtom(f.atoms.items[ent.start + i], flag, depth + 1);
        },
        // The answer of a function parameter escapes: the contract says so,
        // and the caller that knows the function lets what it answers escape.
        .answer => if (flag & flag_e != 0) {
            f.drafts.items[r.index].ans_escapes = true;
        },
        .shared => {},
    }
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
};

/// What the operation reads of operand `o` reaches the targets `ws`; `skip`
/// is the written entry of the written operand itself, and `suffix` the
/// written part below it. Another part below the same entry is another
/// operand: a cell at two parts of one value is no `own` cell.
fn otherReaches(f: *Frame, o: Other, ws: []const Atom, skip: u32, suffix: []const u64) Error!bool {
    if (o.v == v_none or o.v == v_shared) return false;
    const n = f.nodes.items[o.v];
    if (n.tag == .fnref) return false;
    if (o.self_only) {
        const place = f.placeOfVal(o.v) orelse return false;
        if (whole(n.tag)) return f.reach(o.v, ws);
        const self = try f.m.selfLoc(place);
        for (f.m.loc.layoutEntries(try f.m.loc.layoutOf(place)), 0..) |e, k| if (e.loc == self) {
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
    for (cov, 0..) |c, k| {
        if (c == skip and skip != none) {
            const wl = want orelse continue;
            if (f.m.loc.layoutEntries(own_layout)[k].loc == wl) continue;
        }
        if (c == Loc.all) {
            // The written entry itself, when it is the one flagged entry.
            if (skip != none or !any_flag) continue;
        } else if (c != none and o.flags[c] == 0) continue;
        f.scratch.clearRetainingCapacity();
        _ = try f.leaves(o.v, @intCast(k), &f.scratch);
        if (skip != none and n.tag == .ref) {
            // Another location of the written operand itself, which is a part
            // of one root: two locations of it are two sets of cells, though
            // one atom of the frame can name both (the entry level and the
            // deep level of a part of a recursive value). Only a cell that it
            // holds through another root can be a target too.
            for (f.scratch.items) |x| for (ws) |w| {
                if (!f.overlap(x, w)) continue;
                if (x.via == w.via and (x.via == none or f.roots.items[x.via].linear)) continue;
                return true;
            };
            continue;
        }
        if (f.atomsReach(f.scratch.items, ws)) return true;
    }
    return false;
}

/// Judge a write of the atoms `f.atoms[w..]`: what can be decided now is; the
/// reads after it are judged when the frame ends (`finishDemands`).
fn demand(f: *Frame, w: u32, in: DemandIn) Error!void {
    // A write of a new name is a write of the cells' old names too: the
    // leaves of a `version` location have them.
    try f.uniqueTail(&f.atoms, w);
    const wn: u32 = @intCast(f.atoms.items.len - w);
    var token_inst = in.point;
    if (in.op == .call and in.callee_inst != none) token_inst = in.callee_inst;
    if (f.chain_root != none and in.op != .supply) token_inst = f.chain_root;
    var d: Demand = .{
        .point = in.point,
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
    for (0..wn) |i| {
        const a = f.atoms.items[w + i];
        switch (f.roots.items[a.root].kind) {
            .shared => d.refused = .unknown,
            .capture => d.refused = .captured,
            .answer => if (in.op != .supply) {
                d.refused = .call;
            },
            .param, .local => {},
        }
        if (d.refused != null) break;
    }
    if (d.refused == null and in.dup) d.refused = .element;
    if (d.refused == null) {
        f.judge_ctx = f.cur_ctx;
        f.judge_point = d.point;
        for (in.others, 0..) |o, k| {
            if (try f.otherReaches(o, f.atoms.items[w..][0..wn], if (k == in.arg) in.se else none, if (k == in.arg) in.suffix else &.{})) {
                d.refused = .disjoint;
                break;
            }
        }
        f.judge_ctx = none;
        f.judge_point = none;
    }
    if (d.refused == null) {
        for (f.escapes.items) |e| {
            if (!f.compatible(e.ctx, f.cur_ctx)) continue;
            if (f.overlapAny(f.atoms.items[e.start..][0..e.len], f.atoms.items[w..][0..wn])) {
                d.refused = .escaped;
                break;
            }
        }
    }
    // The contract asks the caller for what the body writes of a parameter.
    if (in.op != .supply) for (0..wn) |i| f.markAtom(f.atoms.items[w + i], flag_w, 0);
    // A write of a cell that a function parameter was handed before: a function that keeps it reads the edit.
    if (in.op != .supply and wn != 0) for (f.answers.items) |an| {
        if (f.overlapAny(an.base.items, f.atoms.items[w..][0..wn])) f.drafts.items[an.di].rewrites = true;
    };
    try f.demands.append(f.gpa, d);
}

const Ground = enum(u8) { fresh, call, param };

fn groundOf(f: *Frame, a: Atom, depth: u32) Ground {
    const r = f.roots.items[a.root];
    switch (r.kind) {
        .param, .capture => return .param,
        .local => {
            const ent = f.rents.items[r.ent + a.e];
            var g: Ground = if (r.call) .call else .fresh;
            if ((ent.kind == .taken or ent.kind == .version) and depth < 8) for (0..ent.len) |i| {
                const b = f.groundOf(f.atoms.items[ent.start + i], depth + 1);
                if (@backingInt(b) > @backingInt(g)) g = b;
            };
            return g;
        },
        else => return .fresh,
    }
}

/// The reads after each write, and the report lines.
fn finishDemands(f: *Frame) Error!void {
    for (f.demands.items) |*d| {
        const ws = f.atoms.items[d.w..][0..d.wn];
        if (d.refused == null) {
            f.skip_answer = d.skip;
            f.judge_ctx = d.ctx;
            f.judge_point = d.point;
            for (f.uses.items) |u| {
                // A read at a later point: an instruction's number is after each of its operands'.
                if (u.point <= d.point) continue;
                if (!f.compatible(u.ctx, d.ctx)) continue;
                if (try f.useReaches(u, ws)) {
                    d.refused = .later_use;
                    d.detail = try f.m.useText(f, u.point);
                    break;
                }
            }
            f.skip_answer = none;
            f.judge_ctx = none;
            f.judge_point = none;
        }
        if (d.op == .supply) {
            if (d.refused != null and d.draft != none) f.drafts.items[d.draft].free[d.slot] = false;
            if (!d.send) continue;
        }
        var g: Ground = .fresh;
        for (ws) |a| {
            const x = f.groundOf(a, 0);
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

fn bindLocal(f: *Frame, local: u32, v: Val) void {
    const l = f.d.locals_start + local;
    f.m.lv[l] = v;
    f.m.lframe[l] = f.id;
}

fn bindPattern(f: *Frame, pat: u32, v: Val) Error!void {
    const m = f.m;
    const data = m.datas[pat];
    switch (m.tags[pat]) {
        .pat_var => f.bindLocal(data.lhs, v),
        .pat_as => {
            f.bindLocal(data.rhs, v);
            try f.bindPattern(data.lhs, v);
        },
        .pat_tuple => for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index), 0..) |p, k| {
            try f.bindPattern(p.int(), try f.project(v, .{ .kind = .index, .payload = @intCast(k) }));
        },
        .pat_ctor => {
            const args = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            if (args.len == 0) return;
            const info = m.ctorInfo(data.lhs);
            for (args, 0..) |p, k| {
                // A constructor that the walk has no row for: its argument can be any part of `v`.
                const part = if (info) |ci| try f.project(v, try m.ctorStep(ci.ordinal, @intCast(k))) else try f.unknownOf(try m.placeOfInst(p.int()), &.{v});
                try f.bindPattern(p.int(), if (v == v_none) v_none else part);
            }
        },
        .pat_list => for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| {
            // The rest of a list pattern is a view of the list: the same storage, the same elements.
            if (m.tags[p.int()] == .pat_spread) try f.bindPattern(m.datas[p.int()].lhs, v) else try f.bindPattern(p.int(), try f.project(v, Step.elem));
        },
        .pat_record => for (m.bir.extraSlice(Bir.inlineRange(data), u32)) |local| {
            const name = m.bir.locals[f.d.locals_start + local].name;
            const part = if (name == .none) try f.unknownOf(try m.placeOfLocal(f.d, local), &.{v}) else try f.project(v, .{ .kind = .field, .payload = @intCast(m.fieldRank(name)) });
            f.bindLocal(local, part);
        },
        else => {},
    }
}

/// Whether matching pattern `pat` reads a list's storage.
fn readsList(f: *Frame, pat: u32) bool {
    const m = f.m;
    const data = m.datas[pat];
    switch (m.tags[pat]) {
        .pat_list => return true,
        .pat_as => return f.readsList(data.lhs),
        .pat_tuple => {
            for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| if (f.readsList(p.int())) return true;
            return false;
        },
        .pat_ctor => {
            for (m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index)) |p| if (f.readsList(p.int())) return true;
            return false;
        },
        else => return false,
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
    switch (m.tags[inst]) {
        .let => {
            const bindings = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.lhs)), Inst.Index);
            try f.enterLet(inst, bindings);
            for (bindings) |b| try f.binding(b.int());
            return f.eval(data.rhs, mode, tail);
        },
        .case => return f.caseOf(inst, mode, tail),
        else => {},
    }
    const v = try f.evalInner(inst, mode);
    if (mode == .value) try f.mention(v, inst);
    if (tail) {
        try f.readAll(v, inst);
        if (!try f.makesObject(inst)) f.tail_old = true;
    }
    return v;
}

/// Whether `inst` makes the object that is its value: a record, a tuple or
/// a list literal, a record update (a copy), or a call of a declaration
/// whose each answer is one of these. A constructor application is not one:
/// a type of one constructor with one field is its field in a release build.
fn makesObject(f: *Frame, inst: u32) Error!bool {
    const m = f.m;
    switch (m.tags[inst]) {
        .record, .tuple, .list, .record_update => return true,
        .call => {
            const callee = m.datas[inst].lhs;
            if (m.tags[callee] != .top and m.tags[callee] != .ext_value) return false;
            if (m.spreadOf(f.d, inst) != null) return false;
            const t = m.calleeOf(callee) orelse return false;
            const c = (try m.declContract(t)) orelse return false;
            return !c.old_result;
        },
        else => return false,
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
        .none, .shared, .built, .join, .smear, .unknown => return,
        .later => unreachable, // read through `capVal` only
    }
    try f.flowTop(v, inst);
}

fn flowTop(f: *Frame, v: Val, inst: u32) Error!void {
    const site: Site = .{ .inst = inst };
    const top: Use = .{ .kind = .top, .id = f.useId(), .site = &site };
    try f.flow(v, &top);
}

fn useId(f: *Frame) u32 {
    f.next_use += 1;
    return f.next_use - 1;
}

/// Whether the function lets one of its own parameters escape.
fn keepsOwn(c: *const Contract, own: u32) bool {
    const n = if (own <= c.arity) c.off[own] else c.flags.len;
    for (c.flags[0..n]) |x| if (x & flag_e != 0) return true;
    return false;
}

fn writesOwn(c: *const Contract, own: u32) bool {
    if (own > c.arity) return false;
    for (c.flags[0..c.off[own]]) |x| if (x & flag_w != 0) return true;
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
        return v_shared;
    }
    for (f.cap_locals.items, 0..) |l, k| if (l == local) return f.rootVal(f.params.items[f.own_params + k]);
    const place = try m.placeOfLocal(f.d, local);
    // A local of no object needs no root.
    if (try f.layoutLen(place) == 0) return v_none;
    const root = try f.newRoot(.capture, place, none);
    f.roots.items[root].index = @intCast(f.params.items.len);
    try f.params.append(f.gpa, root);
    try f.param_ty.append(f.gpa, m.typeOfLocal(f.d, local));
    try f.cap_locals.append(f.gpa, local);
    return f.rootVal(root);
}

fn evalInner(f: *Frame, inst: u32, mode: Mode) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    switch (m.tags[inst]) {
        .int, .float, .char, .string, .chunk, .unit, .@"error" => return v_none,
        .ctor, .ext_ctor => return f.ctorValue(inst),
        .local => {
            const l = f.d.locals_start + data.lhs;
            // A code binding of a group whose rounds run (the code itself, or
            // another code of its cycle): the known function, with its
            // contract so far.
            if (m.lframe[l] == none) return f.memberValue(data.lhs);
            if (m.lframe[l] == f.id) return m.lv[l];
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
                f.failed = true;
                return v_shared;
            }
            return f.capture(data.lhs);
        },
        .field_access => {
            const base = try f.eval(data.lhs, .callee, false);
            if (base == v_none) return v_none;
            return f.project(base, .{ .kind = .field, .payload = @intCast(m.fieldRank(@fromBackingInt(data.rhs))) });
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
            const t = m.calleeOf(inst) orelse return f.unknownResult(inst);
            try f.evidence(inst);
            if (try m.isFunction(t)) return f.node(.{ .tag = .fnref, .a = t[0], .b = t[1] });
            // A top-level value: every reader has it, so each cell of it is
            // `shared`. A location that it holds no cell at (`Dict.empty`) holds none here.
            const place = try m.placeOfInst(inst);
            const layout = try m.loc.layoutOf(place);
            const es = m.loc.layoutEntries(layout);
            if (es.len == 0) return v_none;
            const c = (try m.declContract(t)) orelse return v_shared;
            if (c.arity != 0) return v_shared;
            const cov = try m.loc.cover(c.layouts[0], layout);
            var any = false;
            for (cov) |cr| if (cr >= Loc.all or c.res[cr].len != 0) {
                any = true;
            };
            if (!any) return v_none;
            const root = try f.newRoot(.local, place, inst);
            const ent0 = f.roots.items[root].ent;
            for (cov, 0..) |cr, e| f.rents.items[ent0 + e] = if (cr >= Loc.all or c.res[cr].len != 0) .{ .kind = .shared } else .{ .kind = .alias };
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
            return f.built(place, tmp.items);
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
            if (v == v_none) return v_none;
            // The failure leaves the function with the scrutinee's other arm.
            try f.readAll(v, inst);
            try f.returns.append(f.gpa, v);
            // The success: the argument of `Ok` or `Just`, a part of the
            // scrutinee. A `smear` of it would claim its cells and lose that
            // one cell can be at two of its locations.
            if (try m.trySuccess(data.lhs)) |s| return f.project(v, s);
            return f.unknownOf(try m.placeOfInst(inst), &.{v});
        },
        .call => return f.call(inst, mode),
        .method_call => return f.methodCall(inst),
        .type_dispatch => {
            const t = m.bir.extraData(@fromBackingInt(data.rhs), Bir.TypeDispatch);
            for (m.bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Inst.Index)) |a| try f.escape(try f.ev(a.int()), inst);
            return f.unknownResult(inst);
        },
        .markup => {
            var ops: std.ArrayList(Inst.Index) = .empty;
            defer ops.deinit(f.gpa);
            try m.bir.markupValues(f.gpa, @fromBackingInt(data.lhs), &ops);
            // A page's markup reads its values when it is rendered (v1's entry
            // rule): the runtime renders again after each `update`.
            // A value of the model is read. A message that the frame makes
            // here, or a function that answers one, is kept by the runtime
            // until the next render: what it holds escapes.
            for (ops.items) |o| {
                const v = try f.ev(o.int());
                const n = f.nodes.items[v];
                const kept = switch (n.tag) {
                    .built => true,
                    .closure => blk: {
                        // A function that answers markup is a part of the view.
                        const lc = f.codes.items[n.a].contract;
                        for (m.loc.layoutEntries(lc.layouts[lc.arity])) |e| if (e.kind != .@"opaque") break :blk true;
                        break :blk false;
                    },
                    .none, .shared, .ref, .join, .smear, .fnref, .unknown => false,
                    .later => unreachable, // read through `capVal` only
                };
                if (kept) try f.escape(v, inst) else try f.readAll(v, inst);
            }
            // The markup's value holds no value of a hole: the entry rule
            // says that the runtime reads them where it renders (above).
            // That is a rule of the platforms, not a fact that the walk
            // proves (research report 113 §6.4).
            return f.unknownResult(inst);
        },
        else => return v_shared,
    }
}

/// A constructor used as a function value: its contract says that the
/// result's argument `k` is parameter `k`, location for location (for a
/// record alias's constructor, the field that argument `k` is). A
/// constructor that the walk has no row for is a function in the default
/// state (`v_shared`): it asks nothing, and its answer can hold each value
/// in sight (research report 112 §2.5). It is never "no function".
fn ctorValue(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const ty = m.typeOfInst(inst);
    // A constructor with no argument is a value of no object, not a function.
    const ft = m.fnType(ty) orelse return v_none;
    const info = m.ctorInfo(inst) orelse return v_shared;
    const pvars = m.in.store.vars(ft.params);
    if (pvars.len != info.arity) return v_shared;
    const rplace = try m.placeOf(ft.result.toOptional());
    if (try f.layoutLen(rplace) == 0) return v_none;
    if (m.code_contract[inst] == null) {
        const params = try f.gpa.alloc(PlaceId, pvars.len);
        for (params, pvars) |*p, v| p.* = try m.placeOf(v.toOptional());
        const c = try m.emptyContract(params, rplace);
        const lists = try f.gpa.alloc(std.ArrayList(Src), c.res.len);
        for (lists) |*l| l.* = .empty;
        for (0..info.arity) |k| {
            const step = (try m.ctorArgStep(inst, rplace, @intCast(k))) orelse return v_shared;
            const pr = (try m.loc.proj(rplace, step)) orelse return v_shared;
            const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
            const pes = m.loc.layoutEntries(c.layouts[k]);
            for (child, 0..) |ce, j| {
                if (pr.up[j] == none) continue;
                for (pes, 0..) |pe, pj| if (pe.loc == ce.loc) try lists[pr.up[j]].append(f.gpa, .{ .kind = .param, .a = @intCast(k), .e = @intCast(pj) });
            }
        }
        const res = @constCast(c.res);
        for (res, lists) |*r, l| r.* = try CMod.normal(m.arena, l.items);
        for (@constCast(c.flags)) |*x| x.* = flag_r;
        m.code_contract[inst] = c;
    }
    try f.codes.append(f.gpa, .{ .contract = m.code_contract[inst].?, .inst = inst, .own_params = info.arity });
    return f.node(.{ .tag = .closure, .place = try m.placeOf(ty), .a = @intCast(f.codes.items.len - 1) });
}

fn unknownResult(f: *Frame, inst: u32) Error!Val {
    return if (try f.layoutLen(try f.m.placeOfInst(inst)) == 0) v_none else v_shared;
}

fn built(f: *Frame, place: PlaceId, kids: []const Kid) Error!Val {
    if (try f.layoutLen(place) == 0) return v_none;
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
    const root = try f.newRoot(.local, place, inst);
    const r = f.roots.items[root];
    const es = m.loc.layoutEntries(r.layout);
    const self = try m.selfLoc(place);
    const pr = try m.loc.proj(place, Step.elem);
    for (0..es.len) |e| {
        if (es[e].loc == self) {
            f.rents.items[r.ent + e].fresh = true;
            if (base == v_none) {
                if (front == v_none) continue;
                const start: u32 = @intCast(f.atoms.items.len);
                _ = try f.leavesAs(front, place, @intCast(e), &f.atoms);
                try f.uniqueTail(&f.atoms, start);
                var kind: EKind = .derived;
                for (f.atoms.items[start..]) |a| if (a.root == 0) {
                    kind = .shared;
                };
                f.rents.items[r.ent + e] = .{ .kind = kind, .start = start, .len = @intCast(f.atoms.items.len - start), .fresh = true };
                continue;
            }
            const start: u32 = @intCast(f.atoms.items.len);
            _ = try f.leavesAs(base, place, @intCast(e), &f.atoms);
            // The base's storage is the result's: its names here are old.
            var kind: EKind = .version;
            for (f.atoms.items[start..]) |*a| {
                if (a.root == 0) kind = .shared;
                a.dead = inst;
            }
            try f.uniqueTail(&f.atoms, start);
            f.rents.items[r.ent + e] = .{ .kind = kind, .start = start, .len = @intCast(f.atoms.items.len - start), .fresh = true };
            continue;
        }
        const start: u32 = @intCast(f.atoms.items.len);
        var dup = false;
        for (elems) |v| {
            if (v == v_none) continue;
            const before = f.atoms.items.len;
            if (pr) |p| {
                for (p.downOf(@intCast(e))) |j| {
                    if (try f.leavesAs(v, p.child, j, &f.atoms)) dup = true;
                }
            } else _ = try f.allLeaves(v, &f.atoms);
            if (before > start and f.dupOverlap(f.atoms.items[start..before], f.atoms.items[before..])) dup = true;
        }
        for (spreads) |v| {
            if (v == v_none) continue;
            const before = f.atoms.items.len;
            if (try f.leavesAs(v, place, @intCast(e), &f.atoms)) dup = true;
            if (before > start and f.dupOverlap(f.atoms.items[start..before], f.atoms.items[before..])) dup = true;
        }
        try f.uniqueTail(&f.atoms, start);
        var kind: EKind = if (dup) .shared else .derived;
        for (f.atoms.items[start..]) |a| if (a.root == 0) {
            kind = .shared;
        };
        f.rents.items[r.ent + e] = .{ .kind = kind, .start = start, .len = @intCast(f.atoms.items.len - start) };
    }
    // A cell of another root at two locations of the new list: its parts are not apart.
    outer: for (0..es.len) |e1| {
        const a1 = f.rents.items[r.ent + e1];
        if (a1.len == 0) continue;
        for (e1 + 1..es.len) |e2| {
            const a2 = f.rents.items[r.ent + e2];
            if (a2.len == 0) continue;
            if (f.dupOverlap(f.atoms.items[a1.start..][0..a1.len], f.atoms.items[a2.start..][0..a2.len])) {
                f.roots.items[root].linear = false;
                break :outer;
            }
        }
    }
    return f.rootVal(root);
}

fn recordUpdate(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    const fields = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Bir.Field);
    const base = try f.eval(data.lhs, .callee, false);
    const place = try m.placeOfInst(inst);
    var tmp: std.ArrayList(Kid) = .empty;
    defer tmp.deinit(f.gpa);
    for (fields) |fd| {
        const s: Step = .{ .kind = .field, .payload = @intCast(m.fieldRank(fd.name)) };
        try tmp.append(f.gpa, .{ .step = s.word(), .val = try f.ev(fd.value.int()) });
    }
    if (base == v_none) return f.built(place, tmp.items);
    // The update copies the record: each other field is the base's.
    const bplace = f.placeOfVal(base) orelse place;
    const st = m.places.steps(bplace);
    if (base == v_shared and st.steps.len == 0) return v_shared;
    const updated = tmp.items.len;
    for (st.steps) |s| {
        if (s.kind == .level) continue;
        var is_updated = false;
        for (tmp.items[0..updated]) |k| if (k.step == s.word()) {
            is_updated = true;
        };
        if (is_updated) continue;
        const part = try f.project(base, s);
        if (part == v_none) continue;
        try tmp.append(f.gpa, .{ .step = s.word(), .val = part });
    }
    return f.built(place, tmp.items);
}

fn binding(f: *Frame, b: u32) Error!void {
    const m = f.m;
    const data = m.datas[b];
    switch (m.tags[b]) {
        .let_def => {
            const def = m.bir.extraData(@fromBackingInt(data.lhs), Bir.LetDef);
            const l = f.d.locals_start + def.local;
            // Code that a binding above named is made already (`makeCode`).
            if (m.lframe[l] == f.id) return;
            if (m.lcode[l] != none) return f.makeCode(def.local);
            const v = try f.eval(data.rhs, .bind, false);
            f.bindLocal(def.local, v);
        },
        .let_pattern => {
            const v = try f.ev(data.rhs);
            if (f.readsList(data.lhs)) try f.readAll(v, b);
            try f.bindPattern(data.lhs, v);
        },
        .let_stmt => _ = try f.ev(data.rhs),
        else => {},
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
        switch (m.tags[b]) {
            .let_def => f.unbind(m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef).local),
            .let_pattern => f.unbindPattern(m.datas[b].lhs),
            else => {},
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
    const m = f.m;
    const data = m.datas[pat];
    switch (m.tags[pat]) {
        .pat_var => f.unbind(data.lhs),
        .pat_as => {
            f.unbind(data.rhs);
            f.unbindPattern(data.lhs);
        },
        .pat_tuple, .pat_list => for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| f.unbindPattern(p.int()),
        .pat_spread => f.unbindPattern(data.lhs),
        .pat_ctor => for (m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.rhs)), Inst.Index)) |p| f.unbindPattern(p.int()),
        .pat_record => for (m.bir.extraSlice(Bir.inlineRange(data), u32)) |local| f.unbind(local),
        else => {},
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
        switch (m.tags[b]) {
            .let_def => {
                last = @max(last, m.datas[b].rhs);
                const def = m.bir.extraData(@fromBackingInt(m.datas[b].lhs), Bir.LetDef);
                for (m.bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Inst.Index)) |p| last = @max(last, p.int());
            },
            .let_pattern => last = @max(last, @max(m.datas[b].lhs, m.datas[b].rhs)),
            .let_stmt => last = @max(last, m.datas[b].rhs),
            else => {},
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
        try f.readAll(scrut, data.lhs);
        break;
    };
    var outs: std.ArrayList(Val) = .empty;
    defer outs.deinit(f.gpa);
    var ctxs: std.ArrayList(u32) = .empty;
    defer ctxs.deinit(f.gpa);
    for (branches, 0..) |br, k| {
        const bd = m.datas[br.int()];
        const saved = try f.enterArm(inst, @intCast(k));
        try ctxs.append(f.gpa, f.cur_ctx);
        try f.bindPattern(bd.lhs, scrut);
        try outs.append(f.gpa, try f.eval(bd.rhs, if (mode == .bind) .value else mode, tail));
        f.cur_ctx = saved;
    }
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
    const caps = try f.gpa.alloc([]const u32, ms.len);
    @memset(caps, &.{});
    const vals = try f.gpa.alloc(Val, ms.len);
    @memset(vals, v_shared);
    for (ms) |mb| {
        const fnt = m.fnType(mb.ty);
        const pvars: []const Var = if (fnt) |ft| m.in.store.vars(ft.params) else &.{};
        if (mb.local == none or m.code_contract[mb.inst] != null or pvars.len != mb.params.len) continue;
        const places = try f.gpa.alloc(PlaceId, mb.params.len);
        const tys = try f.gpa.alloc(Var.Optional, mb.params.len);
        for (places, tys, pvars) |*p, *t, pv| {
            p.* = try m.placeOf(pv.toOptional());
            t.* = pv.toOptional();
        }
        m.code_contract[mb.inst] = try m.bottomContract(places, tys, try m.placeOf(fnt.?.result.toOptional()));
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
            const rplace = if (fnt) |ft| try m.placeOf(ft.result.toOptional()) else m.var_place;
            const c = try child.finish(rplace);
            if (child.failed) f.failed = true;
            caps[i] = try f.gpa.dupe(u32, child.cap_locals.items);
            const old = m.code_contract[mb.inst];
            const joined = if (old) |o| try CMod.join(m.arena, o, c) else c;
            if (if (old) |o| !CMod.eql(o, joined) else true) changed = true;
            m.code_contract[mb.inst] = joined;
            m.code_caps[mb.inst] = try m.arena.dupe(u32, caps[i]);
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
    const start: u32 = @intCast(f.lists.items.len);
    try f.lists.appendSlice(f.gpa, tmp.items);
    try f.codes.append(f.gpa, .{ .contract = c, .caps = start, .ncaps = @intCast(cap_locals.len), .inst = mb.inst, .own_params = @intCast(mb.params.len) });
    return f.node(.{ .tag = .closure, .place = try m.placeOf(mb.ty), .a = @intCast(f.codes.items.len - 1) });
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
    if (n.tag != .later) return v;
    const l = f.d.locals_start + n.a;
    if (m.lframe[l] == 0 and m.lcode[l] != none) try f.makeCode(n.a);
    if (m.lframe[l] != f.id) {
        f.failed = true;
        return v_shared;
    }
    f.lists.items[i] = m.lv[l];
    return m.lv[l];
}

/// The frame's contract, once its body is walked.
pub fn finish(f: *Frame, result_place: PlaceId) Error!*const Contract {
    const m = f.m;
    try f.finishDemands();
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
        for (tmp.items) |a| f.markAtom(a, flag_r, 0);
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
    for (0..rn) |e| {
        const start: u32 = @intCast(all.items.len);
        const dup = if (result == v_none) false else try f.leavesAs(result, result_place, @intCast(e), &all);
        try f.uniqueTail(&all, start);
        try runs.append(f.gpa, .{ start, @intCast(all.items.len) });
        try dups.append(f.gpa, dup);
    }
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    for (0..rn) |e| {
        srcs.clearRetainingCapacity();
        const mine = all.items[runs.items[e][0]..runs.items[e][1]];
        var shared = dups.items[e] and !m.loc.layoutEntries(layouts[arity])[e].single;
        for (mine) |a| {
            try f.atomSrcs(a, &srcs, 0);
            const r = f.roots.items[a.root];
            // An answer that the body let escape is held somewhere else too.
            if (r.kind == .answer and f.drafts.items[r.index].ans_escapes) shared = true;
            if (r.kind != .local) continue;
            const ent = f.rents.items[r.ent + a.e];
            if (ent.kind != .own and !ent.fresh) continue;
            // A cell that the frame made is `fresh` for the caller only when
            // no other location of the result has it and it did not escape.
            for (0..rn) |e2| {
                if (e2 == e) continue;
                if (f.overlapAny(&.{a}, all.items[runs.items[e2][0]..runs.items[e2][1]])) shared = true;
            }
            for (f.escapes.items) |esc| if (f.overlapAny(&.{a}, f.atoms.items[esc.start..][0..esc.len])) {
                shared = true;
            };
        }
        // A location with no claim still says what it can hold: a caller's holder check needs it.
        if (shared) try srcs.append(f.gpa, Src.shared);
        res[e] = try CMod.normal(m.arena, srcs.items);
        for (res[e]) |s| if (s.kind == .param) {
            flags[off[s.a] + s.e] |= flag_r;
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
    // Whether a cell of a parameter can be at two locations of the result.
    var nonlinear = false;
    for (0..rn) |e1| for (e1 + 1..rn) |e2| {
        if (f.dupOverlap(all.items[runs.items[e1][0]..runs.items[e1][1]], all.items[runs.items[e2][0]..runs.items[e2][1]])) nonlinear = true;
    };
    for (dups.items) |d| if (d) {
        nonlinear = true;
    };
    const c = try m.arena.create(Contract);
    c.* = .{ .arity = arity, .layouts = layouts, .off = off, .flags = flags, .res = res, .fns = fns, .nonlinear = nonlinear, .old_result = f.tail_old };
    return c;
}

/// What atom `a` is for a contract: a parameter location, `fresh`, `shared`, an answer.
fn atomSrcs(f: *Frame, a: Atom, out: *std.ArrayList(Src), depth: u32) Error!void {
    const r = f.roots.items[a.root];
    switch (r.kind) {
        .shared => try out.append(f.gpa, Src.shared),
        .param, .capture => try out.append(f.gpa, .{ .kind = .param, .a = @intCast(r.index), .e = @intCast(a.e) }),
        .answer => try out.append(f.gpa, .{ .kind = .answer, .a = @intCast(f.roots.items[f.drafts.items[r.index].root].index), .e = @intCast(a.e) }),
        .local => {
            const ent = f.rents.items[r.ent + a.e];
            if ((ent.kind == .taken or ent.kind == .version) and depth < 8) {
                for (0..ent.len) |i| try f.atomSrcs(f.atoms.items[ent.start + i], out, depth + 1);
            }
            // The cells of other roots (`alias`, `derived`) are in the list on their own.
            if (ent.kind == .own or ent.fresh) try out.append(f.gpa, Src.fresh);
        },
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
    switch (m.tags[callee]) {
        .ctor, .ext_ctor => {
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
            // A constructor that no row describes: no claim, and each cell of
            // its arguments. A `smear` would claim its cells, and lose that
            // one cell can be at two of its locations.
            if (!known) return f.unknownOf(place, vals.items);
            return f.built(place, tmp.items);
        },
        else => {},
    }
    // The callee, then the arguments in order.
    var code: ?Code = null;
    var fn_root: u32 = none;
    var callee_val: Val = v_none;
    switch (m.tags[callee]) {
        .top, .ext_value => {
            // The evidence of a call is at the call; that of a reference is at the reference.
            try f.evidence(callee);
            try f.evidence(inst);
            if (m.calleeOf(callee)) |t| {
                if (try m.declContract(t)) |c| code = .{ .contract = c, .decl = t, .own_params = c.arity };
            }
        },
        else => {
            callee_val = try f.eval(callee, .callee, false);
            const n = f.nodes.items[callee_val];
            switch (n.tag) {
                .closure => code = f.codes.items[n.a],
                .fnref => {
                    if (try m.declContract(.{ n.a, n.b })) |c| code = .{ .contract = c, .decl = .{ n.a, n.b }, .own_params = c.arity };
                },
                .ref => fn_root = f.ownFnRoot(callee_val),
                .none, .shared, .built, .join, .smear, .unknown => {},
                .later => unreachable, // read through `capVal` only
            }
            // One of several functions, or a function with no contract: no
            // rule follows which code runs, so each of them goes to the `top` use.
            if (code == null and fn_root == none) try f.flowTop(callee_val, inst);
        },
    }
    if (code) |c| if (c.contract.entry and args.len == 1) return f.entryCall(inst, args[0].int());
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    for (args, 0..) |a, k| {
        // An argument at a function parameter flows to that parameter's
        // contract (`apply`). The argument of an identity is the call's value.
        const is_fn = if (code) |c| k < c.contract.arity and (c.contract.fns[k] != null or f.isIdentity(c.contract)) else false;
        try vals.append(f.gpa, try f.eval(a.int(), if (is_fn) .fn_arg else .value, false));
    }
    if (code) |c| return f.apply(inst, callee, c, vals.items, args);
    if (fn_root != none) return f.callParam(inst, callee, fn_root, vals.items, args);
    // An unknown function: it can keep each argument, and its answer has no claim.
    for (vals.items) |v| try f.escape(v, inst);
    if (callee_val != v_none) try f.escape(callee_val, inst);
    return f.unknownResult(inst);
}

/// A code binding whose rounds run, named in a walk: the code itself, or
/// another member of its group (`solveCodes`). It is the known function
/// with its contract so far and the values that it captured, as this frame
/// has them. So a call of it, and each place that it goes to, is judged as
/// for any known function, and no member holds another.
fn memberValue(f: *Frame, local: u32) Error!Val {
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
    f.failed = true;
    return v_shared;
}

fn methodCall(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    const mc = m.bir.extraData(@fromBackingInt(data.rhs), Bir.MethodCall);
    const args = m.bir.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
    // `==`, `<` and their kin call a type's `eq` and `compare`, which only
    // read (language.md §6.5); `Check` refuses one that does more.
    const name = m.symbolText(mc.name);
    const reads = mc.origin != .none or std.mem.eql(u8, name, "compare") or std.mem.eql(u8, name, "eq");
    var code: ?Code = null;
    if (!reads) if (m.methodTarget(inst)) |t| {
        if (try m.declContract(t)) |c| {
            if (c.arity == args.len + 1) code = .{ .contract = c, .decl = t, .own_params = c.arity };
        }
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
    try f.evidence(inst);
    if (reads) {
        for (vals.items) |v| try f.readAll(v, inst);
        return f.unknownResult(inst);
    }
    if (code) |c| return f.apply(inst, inst, c, vals.items, all.items);
    for (vals.items) |v| try f.escape(v, inst);
    return f.unknownResult(inst);
}

/// A function handed as evidence (`where`) is called by code that the checker does not follow.
fn evidence(f: *Frame, inst: u32) Error!void {
    const m = f.m;
    const dt = m.in.dispatch orelse return;
    if (dt.sites.len == 0) return;
    const site = dt.siteOf(@fromBackingInt(inst)) orelse return;
    for (dt.argsAt(site.evidence)) |ti| try f.evidenceTerm(inst, ti, 0);
}

fn evidenceTerm(f: *Frame, inst: u32, ti: anytype, depth: u32) Error!void {
    const m = f.m;
    const dt = m.in.dispatch.?;
    if (depth > 8) return;
    const t: ?[2]u32 = switch (dt.term(ti)) {
        .top => |u| .{ m.in.module, u.decl.int() },
        .ext => |u| if (u.module.int() < m.in.provenance.len) (if (m.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| .{ u.module.int(), d.int() } else null) else null,
        else => null,
    };
    if (t) |target| {
        if (try m.declContract(target)) |c| {
            if (c.writes()) try m.addRefusal(f, inst, .call, "a function that writes its parameter is handed as evidence");
        } else if (try m.isFunction(target)) {
            // No contract: the checker cannot say that it writes nothing.
            try m.addRefusal(f, inst, .call, "a function with no contract is handed as evidence");
        }
    }
    for (dt.argsOfTerm(ti)) |a| try f.evidenceTerm(inst, a, depth + 1);
}

/// The atoms of argument `v` at the callee's entry `se` of the signature
/// layout `sig`. With `suffix`, only the part at that suffix below the entry
/// (a function writes a part of what a type variable stands for). With
/// `deep`, each cell below that part too.
fn argLeaves(f: *Frame, v: Val, sig: u32, se: u32, suffix: []const u64, deep: bool, out: *std.ArrayList(Atom)) Error!bool {
    const m = f.m;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .shared => {
            try out.append(f.gpa, shared_atom);
            return false;
        },
        .closure, .smear, .unknown => return f.leaves(v, 0, out),
        .ref, .built, .join => {},
        .later => unreachable, // read through `capVal` only
    }
    const own = try m.loc.layoutOf(n.place);
    const cov = try m.loc.cover(sig, own);
    var dup = false;
    if (suffix.len != 0) {
        var want: ?u32 = m.loc.layoutEntries(sig)[se].loc;
        for (suffix) |l| {
            want = m.loc.find(want.?, l);
            if (want == null) break;
        }
        if (want) |wl| {
            var found = false;
            // The cell at that part. `deep`: each cell below it too (the
            // part is a wide location of another reading of the type).
            for (m.loc.layoutEntries(own), 0..) |oe, k| if (Loc.hits(cov[k], se) and (oe.loc == wl or (deep and m.loc.isPrefix(wl, oe.loc)))) {
                if (cov[k] != se and !deep) continue;
                found = true;
                if (try f.leaves(v, @intCast(k), out)) dup = true;
            };
            if (found) return dup;
        }
    }
    for (cov, 0..) |c, k| {
        if (!Loc.hits(c, se)) continue;
        if (c == Loc.all) f.hit_all = true;
        if (try f.leaves(v, @intCast(k), out)) dup = true;
    }
    return dup;
}

/// Apply contract `code.contract` to the arguments `vals` at the call `inst`.
fn apply(f: *Frame, inst: u32, callee: u32, code: Code, vals: []const Val, arg_insts: []const Inst.Index) Error!Val {
    const m = f.m;
    const c = code.contract;
    // The values by the contract's parameters: the arguments, then the captures.
    var all: std.ArrayList(Val) = .empty;
    defer all.deinit(f.gpa);
    try all.appendSlice(f.gpa, vals);
    for (0..code.ncaps) |k| try all.append(f.gpa, try f.capVal(code, k));
    if (all.items.len != c.arity) {
        // A partial or an over-application: no rule follows it.
        for (all.items) |v| {
            try f.flowTop(v, inst);
            try f.escape(v, inst);
        }
        if (c.writes()) try m.addRefusal(f, inst, .call, "a function that writes its parameter is not called with all its arguments");
        return f.unknownResult(inst);
    }
    const args = all.items;
    // A function that answers its one parameter as it is (`Js.from`, `Js.to`,
    // `identity`): the value keeps its shape through a type that has none.
    // A function value stays the function that it is: nothing consumed it.
    if (f.isIdentity(c)) {
        try f.readBy(args[0], inst, c.layouts[0], c.flags);
        return args[0];
    }
    const others = try f.gpa.alloc(Other, c.arity);
    for (others, 0..) |*o, j| o.* = .{ .v = args[j], .sig = c.layouts[j], .flags = c.flags[c.off[j]..c.off[j + 1]] };
    // What the callee writes and lets escape.
    for (0..c.arity) |j| {
        const sig = c.layouts[j];
        const n = c.off[j + 1] - c.off[j];
        for (0..n) |se| {
            const fl = c.flags[c.off[j] + se];
            if (fl & flag_w != 0) {
                const w: u32 = @intCast(f.atoms.items.len);
                const dup = try f.argLeaves(args[j], sig, @intCast(se), &.{}, false, &f.atoms);
                // A written argument of no cell asks nothing, and is accepted.
                try f.demand(w, .{
                    .point = inst,
                    .callee_inst = callee,
                    .base_inst = if (j < arg_insts.len) arg_insts[j].int() else none,
                    .loc = m.loc.layoutEntries(sig)[se].loc,
                    .others = others,
                    .arg = j,
                    .se = @intCast(se),
                    .dup = dup and !m.loc.layoutEntries(sig)[se].single,
                    .kind = if (code.decl[0] != none and m.isWorded(code.decl)) .writer else .callsite,
                });
            }
            if (fl & flag_e != 0) {
                const start: u32 = @intCast(f.atoms.items.len);
                _ = try f.argLeaves(args[j], sig, @intCast(se), &.{}, false, &f.atoms);
                try f.noteEscape(start, inst);
            }
        }
    }
    // The functions it is handed: each flows to the contract of its parameter.
    const site: Site = .{ .inst = inst, .callee = callee, .arg_insts = arg_insts, .others = others };
    for (0..c.arity) |j| {
        const fnc = c.fns[j] orelse continue;
        const use: Use = .{ .kind = .call, .id = f.useId(), .c = c, .fnc = fnc, .j = @intCast(j), .args = args, .site = &site };
        try f.flow(args[j], &use);
    }
    // What it reads.
    for (0..c.arity) |j| try f.readBy(args[j], inst, c.layouts[j], c.flags[c.off[j]..c.off[j + 1]]);
    // The level that the result's sources are read at: no function of it is in work.
    const base: Use = .{ .kind = .call, .id = f.useId(), .c = c, .args = args, .site = &site };
    // The result.
    const place = try m.placeOfInst(inst);
    const layout = try m.loc.layoutOf(place);
    const es = m.loc.layoutEntries(layout);
    if (es.len == 0) return v_none;
    const root = try f.newRoot(.local, place, inst);
    f.roots.items[root].call = true;
    f.roots.items[root].linear = !c.nonlinear;
    const cov = try m.loc.cover(c.layouts[c.arity], layout);
    const ent0 = f.roots.items[root].ent;
    for (0..es.len) |e| {
        const cr = cov[e];
        if (cr == none) {
            f.rents.items[ent0 + e] = .{ .kind = .shared };
            continue;
        }
        const start: u32 = @intCast(f.atoms.items.len);
        var st: SrcState = .{ .inst = inst };
        if (cr == Loc.all) {
            for (c.res, 0..) |srcs, ri| try f.expandSrcs(&base, srcs, c.layouts[c.arity], @intCast(ri), layout, @intCast(e), &st);
        } else try f.expandSrcs(&base, c.res[cr], c.layouts[c.arity], cr, layout, @intCast(e), &st);
        // The cells of the arguments that the result holds, in an order of its own.
        var kind: EKind = .derived;
        const single = es[e].single;
        // A written location that the callee answers has a new name; so has
        // an element that a trusted loop took out.
        if (st.written) kind = .version;
        if (c.taken) kind = .taken;
        if (st.shared or (st.dup and !single)) kind = .shared;
        try f.uniqueTail(&f.atoms, start);
        for (f.atoms.items[start..]) |a| if (a.root == 0) {
            kind = .shared;
        };
        // A location with no source holds no cell: nothing is in it.
        f.rents.items[ent0 + e] = .{ .kind = kind, .start = start, .len = @intCast(f.atoms.items.len - start), .fresh = st.fresh };
    }
    try f.sourcesApart(&base, root, layout, cov);
    return f.rootVal(root);
}

/// A contract says which sources each location of the result has. It says
/// in two ways that two sources are two cells: two locations of the result
/// are apart (`nonlinear` is false), and one summary location holds each
/// cell once. The callee can know that of one source that it puts at two
/// places. It cannot know it of two sources: that rests on the arguments,
/// which can be one cell (`keep2 ( q, q )`), and on the functions that it
/// was handed, whose answers can be any cell that they were handed
/// (`( f xs, xs )` with a function that answers its parameter). This frame
/// knows both, and it reads the claim in two steps.
///
/// 1. **The arguments** (`argsApart`). When no cell is at two places of the
///    arguments, two parameter sources are two cells: two arguments have no
///    cell in common, and two locations of one argument are apart by that
///    argument's own claim. When a cell is at two places, the callee's claim
///    has no ground: the locations of the result are not apart, and a
///    summary location with an answer or with two sources has no claim.
/// 2. **Each pair with an answer.** What the function answers is read here
///    (`answerOfParam`). If the two sources can be one cell, the claim does
///    not hold: two locations are not apart, or the summary location has no
///    claim.
///
/// Pairs with an answer that need no check:
///
/// - an answer and a parameter location that the function was handed, in
///   one summary location: they are alternatives, or the supply is not
///   `free` (which `answerOfCode` reads as one cell at two places);
/// - one answer source at one summary location: the callee hands the
///   function a cell once, or its supply is not `free`. (Step 1 has the
///   case of two calls that are handed one cell: `[ f x, f y ]` with one
///   list as `x` and `y`.)
/// - two entries of one answer, when the function is known, its contract
///   says that they are apart, and what it was handed is apart;
/// - an answer and another source in two parts of one wide entry of the
///   callee's result (a type variable): the callee cannot make a value of
///   that type from two sources, so they are alternatives, each a whole
///   value.
fn sourcesApart(f: *Frame, base: *const Use, root: u32, layout: u32, cov: []const u32) Error!void {
    const m = f.m;
    const c = base.c;
    const es = m.loc.layoutEntries(layout);
    // Nothing to compare: no source that is a cell of this frame, or one
    // source at one location (one wide source can be at several locations).
    var count: u32 = 0;
    for (c.res) |srcs| for (srcs) |s| if (s.kind == .param or s.kind == .answer) {
        count += 1;
    };
    if (count == 0 or (count < 2 and es.len < 2)) return;
    const rsig = c.layouts[c.arity];
    const ent0 = f.roots.items[root].ent;
    // Per result entry: the atoms of each source, as runs of `buf`.
    const Run = struct { e: u32, ri: u32, src: Src, start: u32, end: u32 };
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(f.gpa);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(f.gpa);
    var suffix: std.ArrayList(u64) = .empty;
    defer suffix.deinit(f.gpa);
    const w = f.atoms.items.len;
    defer f.atoms.shrinkRetainingCapacity(w);
    for (0..es.len) |e| {
        // No source: the entry has no claim already.
        if (cov[e] == none) continue;
        // The fallback cover gives the entry each source of each location, as `apply` does.
        const lo: usize = if (cov[e] == Loc.all) 0 else cov[e];
        const hi: usize = if (cov[e] == Loc.all) c.res.len else cov[e] + 1;
        for (lo..hi) |cr| {
            // The part of the callee's result entry that this entry is, as in `expandSrcs`.
            suffix.clearRetainingCapacity();
            const cloc = m.loc.layoutEntries(rsig)[cr].loc;
            if (m.loc.isPrefix(cloc, es[e].loc)) try f.suffixOf(es[e].loc, cloc, &suffix);
            for (c.res[cr]) |s| {
                f.atoms.shrinkRetainingCapacity(w);
                switch (s.kind) {
                    .fresh, .shared => continue,
                    .param => {
                        if (s.a >= base.args.len) continue;
                        // A cell that is two times in this one location of the one
                        // argument is `apply`'s to see: `expandSrcs` ran for this entry.
                        _ = try f.pairedLeaves(base.args[s.a], c.layouts[s.a], s.e, rsig, @intCast(cr), layout, @intCast(e));
                    },
                    .answer => {
                        var st: SrcState = .{ .inst = base.site.inst };
                        try f.answerOfParam(base, s, suffix.items, &st, 0);
                    },
                }
                if (f.atoms.items.len == w) continue;
                const start: u32 = @intCast(buf.items.len);
                try buf.appendSlice(f.gpa, f.atoms.items[w..]);
                try runs.append(f.gpa, .{ .e = @intCast(e), .ri = @intCast(cr), .src = s, .start = start, .end = @intCast(buf.items.len) });
            }
        }
    }
    if (runs.items.len == 0) return;
    var answers = false;
    for (runs.items) |x| if (x.src.kind == .answer) {
        answers = true;
    };
    if (!answers and runs.items.len < 2) return;
    // Step 1: the arguments.
    const args_apart = try f.argsApart(base.args);
    if (!args_apart) {
        if (es.len > 1) f.roots.items[root].linear = false;
        for (runs.items, 0..) |x, xi| {
            if (es[x.e].single) continue;
            var two = x.src.kind == .answer;
            for (runs.items, 0..) |y, yi| if (yi != xi and y.e == x.e) {
                two = true;
            };
            if (two) f.rents.items[ent0 + x.e].kind = .shared;
        }
        return;
    }
    if (!answers) return;
    // Step 2: each pair with an answer.
    for (runs.items, 0..) |x, xi| for (runs.items[xi + 1 ..]) |y| {
        const xa = x.src.kind == .answer;
        const ya = y.src.kind == .answer;
        if (!xa and !ya) continue;
        const same_e = x.e == y.e;
        // A location that names one value holds one of its sources.
        if (same_e and es[x.e].single) continue;
        if (!same_e and !f.roots.items[root].linear) continue;
        const same_fn = xa and ya and x.src.a == y.src.a;
        const fn_apart = same_fn and x.src.a < base.args.len and try f.linearFn(base.args[x.src.a]);
        if (!same_e and x.ri == y.ri and m.loc.layoutEntries(rsig)[x.ri].kind.wide()) {
            // Two parts of one value.
            if (!same_fn or fn_apart) continue;
        } else if (xa and ya) {
            if (same_fn and x.src.e == y.src.e and same_e) continue;
            if (same_fn and x.src.e != y.src.e and fn_apart) continue;
        } else if (same_e) {
            const ans = if (xa) x.src else y.src;
            const par = if (xa) y.src else x.src;
            if (handsOn(c.fns[ans.a], par)) continue;
        }
        if (!f.overlapAny(buf.items[x.start..x.end], buf.items[y.start..y.end])) continue;
        if (same_e) {
            f.rents.items[ent0 + x.e].kind = .shared;
        } else f.roots.items[root].linear = false;
    };
}

/// Whether the function contract `fnc` hands the function the parameter location `par`.
fn handsOn(fnc: ?*const CMod.Fn, par: Src) bool {
    const g = fnc orelse return false;
    for (g.supply) |srcs| for (srcs) |x| if (x.kind == .param and x.a == par.a and x.e == par.e) return true;
    return false;
}

/// Whether the function value `v` is known code whose contract says that
/// two parts of its answer are apart, and that contract can know it: no part
/// of the answer is the answer of another function.
fn linearFn(f: *Frame, v: Val) Error!bool {
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        for (0..n.b) |ki| if (!try f.linearFn(f.lists.items[n.a + 2 * ki])) return false;
        return true;
    }
    const code = (try f.codeOf(v)) orelse return false;
    if (code.contract.nonlinear) return false;
    for (code.contract.res) |srcs| for (srcs) |x| if (x.kind == .answer) return false;
    return true;
}

/// Whether no cell is at two places of the arguments `args`: in two
/// arguments, or in two parts of one argument (`( q, q )`). A callee's
/// contract is written for arguments that are so, and its claims about two
/// sources of its result hold only then (`sourcesApart`).
fn argsApart(f: *Frame, args: []const Val) Error!bool {
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(f.gpa);
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    for (args) |v| if (!try f.partsOf(v, &buf, &runs, 0)) return false;
    return f.runsApart(buf.items, runs.items);
}

/// Whether no cell is at two places of the one value `v`.
fn valueApart(f: *Frame, v: Val, depth: u32) Error!bool {
    var buf: std.ArrayList(Atom) = .empty;
    defer buf.deinit(f.gpa);
    var runs: std.ArrayList([2]u32) = .empty;
    defer runs.deinit(f.gpa);
    if (!try f.partsOf(v, &buf, &runs, depth)) return false;
    return f.runsApart(buf.items, runs.items);
}

fn runsApart(f: *const Frame, buf: []const Atom, runs: []const [2]u32) bool {
    for (runs, 0..) |x, i| for (runs[i + 1 ..]) |y| {
        if (f.dupOverlap(buf[x[0]..x[1]], buf[y[0]..y[1]])) return false;
    };
    return true;
}

/// The parts of the value `v` as runs of atoms. False when `v` cannot claim
/// that its own parts are apart. One case for each kind of value:
///
/// - no object, a function with no captured value: no cell;
/// - no claim (`shared`): its cells are no atoms, and a location that gets
///   them has no claim either;
/// - a part of a root: one part. A root that the frame made says if its
///   parts are apart (`linear`); a parameter and a captured local are apart
///   by the rule that this function checks at each call: two parameters,
///   and two parts of one, are sources of the frame's result, and the caller
///   judges them with its own arguments. The answer of the frame's own
///   function parameter is one part too. The frame cannot know if its parts
///   are apart, and it does not claim that: its contract names them as
///   answers, and the caller that knows the function decides
///   (`sourcesApart`, step 2);
/// - a tuple, a record or a constructor application: each item is a part,
///   and each item must be apart in itself. A nest that is too deep to
///   follow has no claim;
/// - one of several values: each of them must be apart in itself. Two of
///   them are never one value, so together they are one part;
/// - a function value: what it captured is one part. An answer never has a
///   claim on a captured cell, so two captured locals that are one cell need
///   no check here;
/// - every cell at every location (`smear`), or a value that the walk
///   cannot follow (`unknown`): one cell can be at two.
fn partsOf(f: *Frame, v: Val, buf: *std.ArrayList(Atom), runs: *std.ArrayList([2]u32), depth: u32) Error!bool {
    if (v == v_none or v == v_shared) return true;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .shared, .fnref => return true,
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
            if (r.kind == .local and !r.linear) return false;
        },
        .closure => {},
        .smear, .unknown => {
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

const SrcState = struct {
    fresh: bool = false,
    shared: bool = false,
    dup: bool = false,
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
    for (f.atoms.items[from..]) |*a| a.dead = st.inst;
    st.written = true;
}

/// Append to `f.atoms` what the sources `srcs` of the callee's result entry
/// `cr` are for the caller's result entry `e`.
fn expandSrcs(f: *Frame, base: *const Use, srcs: []const Src, rsig: u32, cr: u32, rlayout: u32, e: u32, st: *SrcState) Error!void {
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
    // Two locations of one argument are two sets of cells, though one atom
    // of the caller can name both (the entry level and the deep level of a
    // part of a recursive value). So the overlap test is between arguments.
    var group = first;
    var group_param: u32 = none;
    f.hit_all = false;
    for (srcs) |s| {
        const before = f.atoms.items.len;
        if (s.kind != .param or s.a != group_param or f.hit_all) {
            group = before;
            group_param = if (s.kind == .param) s.a else none;
            f.hit_all = false;
        }
        switch (s.kind) {
            .fresh => st.fresh = true,
            .shared => st.shared = true,
            .param => {
                if (s.a >= args.len) {
                    st.shared = true;
                    continue;
                }
                if (try f.pairedLeaves(args[s.a], c.layouts[s.a], s.e, rsig, cr, rlayout, e)) st.dup = true;
                if (c.flags[c.off[s.a] + s.e] & (flag_w | flag_s) != 0) f.oldNames(before, st);
            },
            .answer => {
                // An answer that is a cell the callee handed out as its own
                // is not in the callee's other sources (`answerOfCode` says
                // `dup` when the callee could hand a cell twice).
                try f.answerOfParam(base, s, st.suffix, st, 0);
                continue;
            },
        }
        if (group > first and f.dupOverlap(f.atoms.items[first..group], f.atoms.items[before..])) st.dup = true;
        if (f.hit_all and before > group and f.dupOverlap(f.atoms.items[group..before], f.atoms.items[before..])) st.dup = true;
    }
}

/// The atoms of argument `v` at the callee's parameter entry `pe`, for the
/// caller's result entry `e`: when both are below a type variable, the part
/// of the argument at the same place below it.
fn pairedLeaves(f: *Frame, v: Val, psig: u32, pe: u32, rsig: u32, cr: u32, rlayout: u32, e: u32) Error!bool {
    const m = f.m;
    const pentry = m.loc.layoutEntries(psig)[pe];
    const rentry = m.loc.layoutEntries(rsig)[cr];
    if (!(pentry.kind.wide() and rentry.kind.wide())) return f.argLeaves(v, psig, pe, &.{}, false, &f.atoms);
    const rloc = m.loc.layoutEntries(rlayout)[e].loc;
    // The fallback cover: the caller's entry is not below the callee's.
    if (!m.loc.isPrefix(rentry.loc, rloc)) return f.argLeaves(v, psig, pe, &.{}, false, &f.atoms);
    var labels: std.ArrayList(u64) = .empty;
    defer labels.deinit(f.gpa);
    try m.loc.labels(rloc, &labels, f.gpa);
    const skip = m.loc.loc_depth.items[rentry.loc];
    // A wide entry of the caller's own type stands for each cell below that place.
    return f.argLeaves(v, psig, pe, labels.items[skip..], m.loc.layoutEntries(rlayout)[e].kind.wide(), &f.atoms);
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

/// Whether the contract is that of a function that answers its one parameter
/// as it is and does nothing else with it.
fn isIdentity(f: *const Frame, c: *const Contract) bool {
    const m = f.m;
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
        .none, .shared, .ref, .built, .join, .smear, .unknown => null,
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
    if (use.depth > 16) {
        // Too deep to follow: the default.
        const top: Use = .{ .kind = .top, .id = f.useId(), .site = use.site };
        return f.flow(v, &top);
    }
    const n = f.nodes.items[v];
    if (n.tag == .join) {
        // One of several values: each of them is in the location.
        for (0..n.b) |ki| try f.flow(f.lists.items[n.a + 2 * ki], use);
        return;
    }
    // The holder lets the function's answer escape: each cell that the answer can hold escapes here.
    if (use.kind != .top and use.fnc.ans_escapes) try f.escapeAnswer(v, use);
    if (try f.codeOf(v)) |code| return f.flowCode(v, code, use);
    const root = f.ownFnRoot(v);
    if (f.isFnRoot(root)) return f.flowOwn(root, use);
    return f.flowUnknown(v, use);
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
    if (use.kind == .top or use.fnc.lost or code.own_params != use.fnc.arity) {
        // No contract describes the holder: the function must ask nothing.
        if (writesOwn(lc, code.own_params)) try f.refuse(&use, .call, "a function that writes its parameter goes where the checker does not follow it");
        try f.captureEscapes(code, inst);
        if (use.kind != .top) {
            // A callee lost it. It can keep what it hands, and it can run the
            // function at any later time: what the function captured is held from here on.
            try f.escapeSupplies(&use);
            try f.escape(v, inst);
        }
        const top: Use = .{ .kind = .top, .id = f.useId(), .site = use.site, .depth = use.depth, .code = code };
        return f.flowCaptures(code, &top);
    }
    if (use.rewrites() and keepsOwn(lc, code.own_params)) try f.refuse(&use, .supply, "the function keeps a value that the callee changes later");
    if (use.fnc.called) try f.captureEscapes(code, inst);
    for (0..use.fnc.arity) |k| {
        const n = lc.off[k + 1] - lc.off[k];
        for (0..n) |le| {
            const fl = lc.flags[lc.off[k] + le];
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
    try f.flowCaptures(code, &use);
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
    return .{ .kind = .inner, .id = f.useId(), .c = lc, .fnc = lf, .j = j, .args = args, .own = code.own_params, .up = up, .site = up.site, .depth = up.depth + 1 };
}

/// The frame's own function parameter meets a use: what the use hands it,
/// this frame hands it. The contract of the frame says so, and the caller
/// that knows the function judges it.
fn flowOwn(f: *Frame, root: u32, use_in: *const Use) Error!void {
    const m = f.m;
    var use = use_in.*;
    use.root = root;
    const di = try f.draftOf(root, null);
    const inst = use.site.inst;
    f.drafts.items[di].used = true;
    if (use.kind == .top or use.fnc.lost or f.drafts.items[di].lost or f.drafts.items[di].arity != use.fnc.arity) {
        f.drafts.items[di].lost = true;
        if (use.kind != .top) try f.escapeSupplies(&use);
        return;
    }
    if (use.fnc.called) f.drafts.items[di].called = true;
    if (use.rewrites()) f.drafts.items[di].rewrites = true;
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
    if (use.fnc.lost) try f.escape(v, use.site.inst);
    if (use.rewrites()) try f.refuse(use, .supply, "the callee changes a value after it handed it to a function that the checker does not know");
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
        try out.append(f.gpa, .{ .fe = none, .free = false, .srcs = CMod.shared_only });
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
        try m.loc.belowWide(sig, entry.loc, fe, &below, f.gpa);
        if (below.items.len != 0) {
            // The location that is asked for, when the use's type has it.
            var at: ?u32 = if (rel != null) entry.loc else null;
            if (rel) |labels| for (labels) |l| {
                at = m.loc.find(at.?, l);
                if (at == null) break;
            };
            const es = m.loc.layoutEntries(sig);
            if (at) |t| {
                // Only the use's entry at that location, or a wide one above it.
                var n: usize = 0;
                for (out.items) |slot| {
                    if (es[slot.fe].loc != t and !(es[slot.fe].kind.wide() and m.loc.isPrefix(es[slot.fe].loc, t))) continue;
                    out.items[n] = slot;
                    n += 1;
                }
                out.shrinkRetainingCapacity(n);
            }
            for (below.items) |i| {
                if (at) |t| if (es[i].loc != t and !(es[i].kind.wide() and m.loc.isPrefix(es[i].loc, t))) continue;
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
    // location (a function over `List a`, handed a `List Int`) hands no cell.
    return m.loc.noObject(sig, entry.loc);
}

/// Whether the function's result entry `k` of layout `fl` can hold a cell
/// of the use's answer entry `ae` of layout `ul`; `cv` is the call map's
/// entry for `k`. The other direction of `slotsOf`: a wide entry of the
/// function holds each cell of the use's entries below it.
fn answersAt(f: *const Frame, ul: u32, ae: u32, fl: u32, k: usize, cv: u32) bool {
    const m = f.m;
    if (Loc.hits(cv, ae)) return true;
    const fe = m.loc.layoutEntries(fl)[k];
    if (!fe.kind.wide()) return false;
    const ue = m.loc.layoutEntries(ul)[ae];
    return m.loc.isPrefix(fe.loc, ue.loc) or m.loc.startsAbove(ue.loc, fe.loc);
}

/// What the source `src` of `use`'s contract is in this frame: `sink` gets
/// each part. `suffix`: only the part at these labels below the source's
/// entry; `deep`: and each cell below that part (the one that asks is a wide
/// location). A parameter of a known function that has the location is what
/// that function's own use hands it: this is the composition.
fn resolve(f: *Frame, use: *const Use, src: Src, suffix: []const u64, deep: bool, sink: anytype, depth: u32) Error!void {
    switch (src.kind) {
        .fresh => try sink.fresh(f),
        .shared => try sink.shared(f),
        .answer => try sink.answer(f, use, src, suffix, deep),
        .param => {
            if (src.a >= use.args.len) return sink.lost(f, use);
            if (use.kind == .inner and src.a < use.own) {
                const up = use.up.?;
                // The default hands a value with no claim.
                if (up.kind == .top) return sink.shared(f);
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

    fn fresh(s: *FlatSink, _: *Frame) Error!void {
        s.st.fresh = true;
    }
    fn shared(s: *FlatSink, _: *Frame) Error!void {
        s.st.shared = true;
    }
    /// The holder can hand one cell to two calls: two answers can be that cell.
    fn held(s: *FlatSink, _: *Frame) Error!void {
        s.st.dup = true;
    }
    fn lost(s: *FlatSink, f: *Frame, use: *const Use) Error!void {
        try f.lostAnswer(use, s.st);
    }
    fn atoms(s: *FlatSink, f: *Frame, h: Handed) Error!void {
        if (h.dup) s.st.dup = true;
        if (h.captured) {
            // Each run is handed the same cell: no claim. The answer still holds it.
            s.st.shared = true;
            return;
        }
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

    fn fresh(_: *EscSink, _: *Frame) Error!void {}
    fn shared(_: *EscSink, _: *Frame) Error!void {}
    fn held(_: *EscSink, _: *Frame) Error!void {}
    fn lost(s: *EscSink, f: *Frame, use: *const Use) Error!void {
        var u: ?*const Use = use;
        while (u) |x| : (u = x.up) for (x.args) |v| try f.escape(v, s.inst);
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

    fn fresh(_: *OwnSink, _: *Frame) Error!void {}
    fn shared(s: *OwnSink, f: *Frame) Error!void {
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
        const sig = h.use.c.layouts[h.a];
        var loc = m.loc.layoutEntries(sig)[h.e].loc;
        for (h.suffix) |l| loc = try m.loc.extend(loc, @bitCast(l));
        try f.demand(h.start, .{
            .point = site.inst,
            .callee_inst = site.callee,
            .base_inst = if (h.a < site.arg_insts.len) site.arg_insts[h.a].int() else none,
            .loc = loc,
            .others = site.others,
            .arg = h.a,
            .se = h.e,
            .suffix = h.suffix,
            .dup = h.dup and !m.loc.layoutEntries(sig)[h.e].single,
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
    fn fresh(s: *DraftSink, f: *Frame) Error!void {
        try s.add(f, Src.fresh);
    }
    fn shared(s: *DraftSink, f: *Frame) Error!void {
        try s.add(f, Src.shared);
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
        try f.supplyAtoms(s.di, s.slot, h.start, site.inst, site.others, h.a, h.e, h.dup);
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
        // The answer of another function: what it can hold.
        const w: u32 = @intCast(f.atoms.items.len);
        var st: SrcState = .{ .inst = site.inst, .whole = true };
        try f.answerOfParam(level, src, suffix, &st, 0);
        if (st.fresh) try s.add(f, Src.fresh);
        if (st.shared) try s.add(f, Src.shared);
        if (st.shared or st.dup) f.drafts.items[s.di].free[s.slot] = false;
        try f.supplyAtoms(s.di, s.slot, w, site.inst, site.others, std.math.maxInt(usize), none, st.dup);
    }
};

/// The known function `code`, in the location of `level`, writes its
/// parameter `k` at its entry `le`: each source of what `level` hands there
/// must be `own`, and the holder must not read it again.
fn ownSupply(f: *Frame, level: *const Use, code: Code, k: u32, le: u32, seen: *Seen) Error!void {
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
    if (lc.nonlinear) return f.refuse(level, .supply, "the function can answer one cell at two places, and the callee hands the answer back");
    const rcov = try m.loc.cover(fnc.layouts[fnc.arity], lc.layouts[lc.arity]);
    var want: ?u32 = m.loc.layoutEntries(fnc.layouts[fnc.arity])[e].loc;
    for (suffix) |l| {
        want = m.loc.find(want.?, l);
        if (want == null) break;
    }
    var exact = false;
    if (!deep) if (want) |wl| for (m.loc.layoutEntries(lc.layouts[lc.arity]), 0..) |re_e, re| if (re_e.loc == wl and Loc.hits(rcov[re], e)) {
        exact = true;
    };
    for (rcov, 0..) |cv, re| {
        if (!f.answersAt(fnc.layouts[fnc.arity], e, lc.layouts[lc.arity], re, cv)) continue;
        if (exact and m.loc.layoutEntries(lc.layouts[lc.arity])[re].loc != want.?) continue;
        if (cv >= Loc.all and m.loc.noObject(fnc.layouts[fnc.arity], m.loc.layoutEntries(lc.layouts[lc.arity])[re].loc)) continue;
        for (lc.res[re]) |ls| switch (ls.kind) {
            .fresh => {},
            .shared => try f.refuse(level, .supply, not_own),
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
            if (!keepsOwn(cc.contract, cc.own_params)) continue;
        }
        try f.refuse(level, .supply, "the function hands a value to a function that can keep it, answers it, and the callee hands it back");
    }
}

/// The answer root of the frame's own function parameter at `root`, in the
/// call in work: its atoms at the entries that the answer entry `ae` of
/// layout `alayout` covers.
fn ownAnswer(f: *Frame, root: u32, alayout: u32, ae: u32, st: *SrcState) Error!void {
    const di = try f.draftOf(root, null);
    f.drafts.items[di].used = true;
    const ai = try f.answerRoot(di, st.inst);
    const root_id = f.answers.items[ai].root;
    const ar = f.roots.items[root_id];
    const dr = f.drafts.items[di];
    const cov = try f.m.loc.cover(alayout, dr.layouts[dr.arity]);
    for (cov, 0..) |cv, k| if (Loc.hits(cv, ae)) try f.atoms.append(f.gpa, .{ .root = root_id, .path = ar.path, .e = @intCast(k) });
}

/// No rule follows this answer. It has no claim, and it can hold a cell of
/// each value in sight: each argument of the call, and each value that a
/// known function on the way captured. A location with no claim keeps what
/// it can hold (report 111 §3.5).
fn lostAnswer(f: *Frame, use: *const Use, st: *SrcState) Error!void {
    st.shared = true;
    var u: ?*const Use = use;
    while (u) |x| : (u = x.up) for (x.args) |a| {
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
    try f.answerOf(level.args[src.a], &other, src.e, st, depth);
}

/// Append to `f.atoms` what the answer of the function value `v`, in the
/// location of `use`, can hold at the answer entry `ae`.
fn answerOf(f: *Frame, v: Val, use: *const Use, ae: u32, st: *SrcState, depth: u32) Error!void {
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
    const m = f.m;
    if (use.kind == .top or depth > 8 or code.own_params != use.fnc.arity) return f.lostAnswer(use, st);
    const fnc = use.fnc;
    const lc = code.contract;
    const cov = try m.loc.cover(fnc.layouts[fnc.arity], lc.layouts[lc.arity]);
    // The known function's result entry at the same part below the answer, when it has one.
    var want: ?u32 = m.loc.layoutEntries(fnc.layouts[fnc.arity])[ae].loc;
    for (st.suffix) |l| {
        want = m.loc.find(want.?, l);
        if (want == null) break;
    }
    var exact = false;
    if (!st.whole) if (want) |wl| for (m.loc.layoutEntries(lc.layouts[lc.arity]), 0..) |re_e, re| if (re_e.loc == wl and Loc.hits(cov[re], ae)) {
        exact = true;
    };
    var psuffix: std.ArrayList(u64) = .empty;
    defer psuffix.deinit(f.gpa);
    for (cov, 0..) |cv, k| {
        if (!f.answersAt(fnc.layouts[fnc.arity], ae, lc.layouts[lc.arity], k, cv)) continue;
        if (exact and m.loc.layoutEntries(lc.layouts[lc.arity])[k].loc != want.?) continue;
        // The function's type is wider here than the holder's: no cell is there.
        if (cv >= Loc.all and m.loc.noObject(fnc.layouts[fnc.arity], m.loc.layoutEntries(lc.layouts[lc.arity])[k].loc)) continue;
        switch (st.visit(use, @intCast(k))) {
            .new => {},
            // In work already: it adds no cell.
            .old => continue,
            .full => return f.lostAnswer(use, st),
        }
        for (lc.res[k]) |ls| switch (ls.kind) {
            .fresh => st.fresh = true,
            .shared => st.shared = true,
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
                    // same cell, so no claim. The answer still holds it.
                    st.shared = true;
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
                const aloc = m.loc.layoutEntries(fnc.layouts[fnc.arity])[ae].loc;
                if (cv < Loc.all and m.loc.isPrefix(kloc, aloc)) {
                    try f.suffixOf(aloc, kloc, &psuffix);
                    rel = try f.gpa.dupe(u64, psuffix.items);
                }
                if (!try f.slotsOf(use, ls.a, lc.layouts[ls.a], ls.e, rel, &slots)) {
                    try f.lostAnswer(use, st);
                    continue;
                }
                var sink: FlatSink = .{ .st = st, .depth = depth };
                const wide = m.loc.layoutEntries(lc.layouts[ls.a])[ls.e].kind.wide();
                for (slots.items) |slot| {
                    // The holder can hand one cell to two calls: two answers can be that cell.
                    if (!slot.free) st.dup = true;
                    // The part of what is handed that the function's parameter entry is.
                    const part = try f.partBelow(lc.layouts[ls.a], ls.e, fnc.layouts[ls.a], slot.fe, &.{}, &psuffix);
                    for (slot.srcs) |ss| try f.resolve(use, ss, part, wide, &sink, 0);
                }
            },
        };
    }
}

/// Each cell that the answer of the function value `v`, in the location of `use`, can hold escapes at the use's site.
fn escapeAnswer(f: *Frame, v: Val, use: *const Use) Error!void {
    const n = f.m.loc.layouts.items[use.fnc.layouts[use.fnc.arity]].len;
    const start: u32 = @intCast(f.atoms.items.len);
    var st: SrcState = .{ .inst = use.site.inst, .whole = true };
    for (0..n) |ae| try f.answerOf(v, use, @intCast(ae), &st, 0);
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
    for (w..end) |i| try f.atomSrcs(f.atoms.items[i], &srcs, 0);
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
    try f.drafts.items[di].supply[slot].append(f.gpa, Src.shared);
    f.drafts.items[di].free[slot] = false;
    const w = f.atoms.items.len;
    var u: ?*const Use = use;
    while (u) |x| : (u = x.up) for (x.args) |v| {
        _ = try f.allLeaves(v, &f.atoms);
    };
    try f.uniqueTail(&f.atoms, w);
    const end = f.atoms.items.len;
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    for (w..end) |i| try f.atomSrcs(f.atoms.items[i], &srcs, 0);
    try f.drafts.items[di].supply[slot].appendSlice(f.gpa, srcs.items);
    const ai = try f.answerRoot(di, point);
    try f.answers.items[ai].base.appendSlice(f.gpa, f.atoms.items[w..end]);
    f.atoms.shrinkRetainingCapacity(w);
}

/// A call of the frame's own function parameter at root `root`.
fn callParam(f: *Frame, inst: u32, callee: u32, root: u32, vals: []const Val, arg_insts: []const Inst.Index) Error!Val {
    const m = f.m;
    const di = try f.draftOf(root, callee);
    f.drafts.items[di].used = true;
    if (f.drafts.items[di].arity != vals.len) {
        f.drafts.items[di].lost = true;
        for (vals) |v| try f.escape(v, inst);
        return f.unknownResult(inst);
    }
    f.drafts.items[di].called = true;
    // The runtime's `send`: the message is given up, so each cell of it must be the sender's own.
    const r0 = f.roots.items[root];
    const sender = r0.index < f.param_ty.items.len and m.isSender(f.param_ty.items[r0.index]);
    const before_demands = f.demands.items.len;
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
            const w: u32 = @intCast(f.atoms.items.len);
            const dup = try f.leavesAs(v, f.drafts.items[di].places[k], @intCast(e), &f.atoms);
            // A send asks for the cells that a write can edit: a list, or what a type variable stands for.
            const ek = m.loc.layoutEntries(layout)[e].kind;
            const asks = sender and (ek == .list or ek == .@"var");
            try f.supplyAtomsSend(di, slot, w, inst, rest, std.math.maxInt(usize), none, dup and !m.loc.layoutEntries(layout)[e].single, if (asks) callee else none, if (asks and k < arg_insts.len) arg_insts[k].int() else none);
        }
    }
    // A message of no cell is a send too: its line says so.
    if (sender and f.demands.items.len == before_demands) {
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
        if (v == v_shared) try f.atoms.append(f.gpa, shared_atom);
        return;
    };
    if (whole(f.nodes.items[v].tag)) {
        _ = try f.leaves(v, 0, &f.atoms);
        return;
    }
    const self = try m.selfLoc(place);
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
    for (m.loc.layoutEntries(try m.loc.layoutOf(place)), 0..) |be, k| if (be.loc == self) try f.lists.append(f.gpa, @intCast(k));
    const nmask: u32 = @intCast(f.lists.items.len - start);
    if (nmask == 0) return;
    try f.uses.append(f.gpa, .{ .point = point, .val = v, .ctx = f.cur_ctx, .mask = start, .nmask = nmask, .all = false });
}

/// Whether the value `v` of `inst` is an object that this instruction made
/// (`makesObject`), or a list that a call answers and made (its storage has
/// the source `fresh` alone).
fn newItem(f: *Frame, inst: u32, v: Val) Error!bool {
    const m = f.m;
    if (try f.makesObject(inst)) return true;
    if (v == v_none or v == v_shared) return false;
    const n = f.nodes.items[v];
    if (n.tag != .ref) return false;
    const r = f.roots.items[n.a];
    if (r.kind != .local or r.inst != inst or n.b != r.path) return false;
    const self = try m.selfLoc(r.place);
    for (m.loc.layoutEntries(r.layout), 0..) |e, k| if (e.loc == self) {
        const ent = f.rents.items[r.ent + k];
        return ent.kind == .own or (ent.len == 0 and ent.fresh and ent.kind != .shared);
    };
    return false;
}

/// A spread literal `[ a, …xs, b ]`: one construction (ownership-v2.md §2.13.2).
fn spreadChain(f: *Frame, inst: u32, sp: Bir.Spread) Error!Val {
    const m = f.m;
    const items = m.bir.spreadItems(sp);
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
fn entryCall(f: *Frame, inst: u32, arg: u32) Error!Val {
    const m = f.m;
    const Field = struct { name: []const u8, code: ?Code };
    var fields: [12]Field = undefined;
    var nfields: usize = 0;
    if (m.tags[arg] == .record) {
        for (m.bir.extraSlice(Bir.inlineRange(m.datas[arg]), Bir.Field)) |fd| {
            const v = try f.eval(fd.value.int(), .fn_arg, false);
            // The runtime keeps the record: what a function of it captured is read at any time.
            try f.escape(v, inst);
            const code = try f.codeOf(v);
            if (nfields == fields.len or code == null) {
                // No row of the entry describes this field: the default.
                try f.flowTop(v, inst);
                continue;
            }
            // The rows below judge what the function does with its own
            // parameters. No row describes what the runtime hands on to a
            // function that it captured: those are in the default.
            const site: Site = .{ .inst = inst };
            const top: Use = .{ .kind = .top, .id = f.useId(), .site = &site, .code = code };
            try f.flowCaptures(code.?, &top);
            fields[nfields] = .{ .name = m.symbolText(fd.name), .code = code };
            nfields += 1;
        }
    } else {
        try f.escape(try f.ev(arg), inst);
    }
    var update: ?Code = null;
    var init_c: ?Code = null;
    var settle: ?Code = null;
    var others: [12]Code = undefined;
    var nothers: usize = 0;
    for (fields[0..nfields]) |fd| {
        const c = fd.code orelse continue;
        if (std.mem.eql(u8, fd.name, "update")) update = c else if (std.mem.eql(u8, fd.name, "init")) init_c = c else if (std.mem.eql(u8, fd.name, "settle")) settle = c else {
            others[nothers] = c;
            nothers += 1;
        }
    }
    // Any other function of the record is called with values that it does not own.
    for (others[0..nothers]) |c| {
        if (writesOwn(c.contract, c.own_params)) try m.addRefusal(f, inst, .unknown, "the runtime calls this function with a value that the function does not own");
    }
    if (init_c) |c| if (writesOwn(c.contract, c.own_params)) try m.addRefusal(f, inst, .unknown, "the runtime calls `init` with a value that the function does not own");
    const up = update orelse {
        if (settle) |c| if (writesOwn(c.contract, c.own_params)) try m.addRefusal(f, inst, .unknown, "the record has no `update`");
        return f.unknownResult(inst);
    };
    const uc = up.contract;
    if (up.own_params == 0) return f.unknownResult(inst);
    const ml = uc.layouts[up.own_params - 1];
    const mes = m.loc.layoutEntries(ml);
    const own = try f.gpa.alloc(bool, mes.len);
    @memset(own, true);
    // The model in a result: the result itself, or the first of a pair.
    const idx0: Loc.Label = .{ .kind = .index, .payload = 0, .cyc = false, .head = 0 };
    const p0 = try m.loc.extend(0, idx0);
    const models = [_]?Code{ init_c, update, settle };
    var changed = true;
    while (changed) {
        changed = false;
        for (models, 0..) |mc, which| {
            const code = mc orelse {
                if (which == 0) for (own) |*o| if (o.*) {
                    o.* = false;
                    changed = true;
                };
                continue;
            };
            const c = code.contract;
            if (which != 0 and code.own_params == 0) continue;
            const model_param: u32 = if (which == 0) none else code.own_params - 1;
            const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
            const pes: []const Loc.Entry = if (which == 0) &.{} else m.loc.layoutEntries(c.layouts[model_param]);
            // Whether the result is the model, or a pair whose first is.
            var direct = true;
            for (res_es) |re| if (m.loc.isPrefix(p0, re.loc)) {
                direct = false;
            };
            for (mes) |me| if (m.loc.isPrefix(p0, me.loc)) {
                direct = true;
            };
            for (mes, 0..) |me, k| {
                if (!own[k]) continue;
                const want = if (direct) me.loc else try m.loc.concat(p0, me.loc);
                var ok = true;
                for (res_es, 0..) |re, ri| {
                    // The location itself, or a wide location above it.
                    if (!(re.loc == want or (re.kind.wide() and m.loc.isPrefix(re.loc, want)))) continue;
                    for (c.res[ri]) |s| switch (s.kind) {
                        .fresh => {},
                        .param => {
                            // One cell at two locations of the model is `own` at neither.
                            if (re.loc == want and which != 0) for (res_es, 0..) |re2, ri2| {
                                if (ri2 == ri) continue;
                                for (c.res[ri2]) |s2| if (s2.kind == .param and s2.a == s.a and s2.e == s.e) {
                                    ok = false;
                                };
                                _ = re2;
                            };
                            if (s.a != model_param) {
                                // The message: the runtime hands it as the function's own (each send is checked).
                                if (which == 0 or s.a >= code.own_params) ok = false;
                                continue;
                            }
                            // From another model location: `own` only when that one is.
                            const from = pes[s.e].loc;
                            var found = false;
                            for (mes, 0..) |me2, k2| if (me2.loc == from or (pes[s.e].kind.wide() and m.loc.isPrefix(from, me2.loc))) {
                                found = true;
                                if (!own[k2]) ok = false;
                            };
                            if (!found) ok = false;
                        },
                        else => ok = false,
                    };
                }
                if (!ok) {
                    own[k] = false;
                    changed = true;
                }
            }
        }
    }
    // What the other functions keep of the model is not `own`: the runtime holds their answers.
    for (others[0..nothers]) |c0| {
        const c = c0.contract;
        for (0..c0.own_params) |pj| {
            const pes = m.loc.layoutEntries(c.layouts[pj]);
            for (pes, 0..) |pe, e| {
                var kept = c.flags[c.off[pj] + e] & (flag_w | flag_e) != 0;
                for (c.res) |rs| for (rs) |s| if (s.kind == .param and s.a == pj and s.e == e) {
                    kept = true;
                };
                if (!kept) continue;
                for (mes, 0..) |me, k| if (me.loc == pe.loc or (pe.kind.wide() and m.loc.isPrefix(pe.loc, me.loc))) {
                    own[k] = false;
                };
            }
        }
    }
    // The verdicts: one for each location that `update` or `settle` writes.
    for ([_]?Code{ update, settle }) |mc| {
        const c0 = mc orelse continue;
        const c = c0.contract;
        for (0..c0.own_params) |pj| {
            const pes = m.loc.layoutEntries(c.layouts[pj]);
            for (pes, 0..) |pe, e| {
                if (c.flags[c.off[pj] + e] & flag_w == 0) continue;
                // The message is the function's own; the model where the rounds keep it so.
                var ok = pj != c0.own_params - 1;
                if (pj == c0.own_params - 1) for (mes, 0..) |me, k| if (me.loc == pe.loc and own[k]) {
                    ok = true;
                };
                try m.addEntryLine(f, inst, c0, pj == c0.own_params - 1, pe.loc, ok);
            }
        }
    }
    return f.unknownResult(inst);
}
