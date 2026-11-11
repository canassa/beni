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
//! - `smear`: every cell of some values, at every location.
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

const Tag = enum(u8) { none, shared, ref, built, join, closure, smear, fnref };
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
const Use = struct { point: u32, val: Val, ctx: u32, mask: u32 = 0, nmask: u32 = 0, all: bool = true };
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
/// A local function's frame: a call of the function itself was met.
self_called: bool = false,
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
uses: std.ArrayList(Use) = .empty,
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
/// answers of one function parameter are not one cell by this test: the
/// caller that knows the function decides (`expandAnswer`).
///
/// Two cells read through one root that holds each cell once (`linear`) are
/// one cell only when that root's own atoms say so: its parts are apart.
fn dupOverlap(f: *const Frame, xs: []const Atom, ys: []const Atom) bool {
    for (xs) |x| {
        if (f.roots.items[x.root].kind == .answer) continue;
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
            for (0..c.ncaps) |ki| _ = try f.allLeaves(f.lists.items[c.caps + ki], out);
            return false;
        },
        .smear => {
            for (0..n.b) |ki| _ = try f.allLeaves(f.lists.items[n.a + ki], out);
            return false;
        },
    }
}

fn whole(tag: Tag) bool {
    return tag == .closure or tag == .smear;
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
        .closure, .smear => return f.leaves(v, 0, out),
        else => {},
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
        .closure, .smear => return f.leaves(v, 0, out),
        else => {},
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
        .smear => {
            for (0..n.b) |ki| if (try f.reach(f.lists.items[n.a + ki], w)) return true;
            return false;
        },
        .closure => {
            const c = f.codes.items[n.a];
            for (0..c.ncaps) |ki| if (try f.reach(f.lists.items[c.caps + ki], w)) return true;
            return false;
        },
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
        else => n.place,
    };
}

/// The part of `v` that step `s` reaches.
fn project(f: *Frame, v: Val, s: Step) Error!Val {
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none => return v_none,
        .shared, .closure, .fnref => return v_shared,
        .ref => {
            const np = (try f.m.loc.pathExtend(n.b, s)) orelse return v_shared;
            const child = f.m.loc.paths.items[np].place;
            if (try f.layoutLen(child) == 0) return v_none;
            return f.refVal(n.a, np);
        },
        .built => {
            for (0..n.b) |ki| if (f.kids.items[n.a + ki].step == s.word()) return f.kids.items[n.a + ki].val;
            // Another constructor's argument holds nothing here; any other
            // step that the value does not name has no claim.
            return if (s.kind == .ctor_arg) v_none else v_shared;
        },
        .join => {
            const pr = (try f.m.loc.proj(n.place, s)) orelse return v_shared;
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
        .smear => {
            const pr = (try f.m.loc.proj(n.place, s)) orelse return v_shared;
            if (try f.layoutLen(pr.child) == 0) return v_none;
            return f.node(.{ .tag = .smear, .place = pr.child, .a = n.a, .b = n.b });
        },
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
fn readBy(f: *Frame, v: Val, point: u32, sig: u32, flags: []const u8, is_fn: bool) Error!void {
    if (v == v_none or v == v_shared) return;
    const n = f.nodes.items[v];
    if (n.tag == .fnref) return;
    if (whole(n.tag)) {
        // A function value: read when the callee reads, calls or keeps it.
        var any = is_fn;
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

fn useReaches(f: *Frame, u: Use, ws: []const Atom) Error!bool {
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
                const part = if (info) |ci| try f.project(v, try m.ctorStep(ci.ordinal, @intCast(k))) else v_shared;
                try f.bindPattern(p.int(), if (v == v_none) v_none else part);
            }
        },
        .pat_list => for (m.bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |p| {
            // The rest of a list pattern is a view of the list: the same storage, the same elements.
            if (m.tags[p.int()] == .pat_spread) try f.bindPattern(m.datas[p.int()].lhs, v) else try f.bindPattern(p.int(), try f.project(v, Step.elem));
        },
        .pat_record => for (m.bir.extraSlice(Bir.inlineRange(data), u32)) |local| {
            const name = m.bir.locals[f.d.locals_start + local].name;
            const part = if (name == .none) v_shared else try f.project(v, .{ .kind = .field, .payload = @intCast(m.fieldRank(name)) });
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
            for (m.bir.extraSlice(m.bir.subRange(@fromBackingInt(data.lhs)), Inst.Index)) |b| try f.binding(b.int());
            return f.eval(data.rhs, mode, tail);
        },
        .case => return f.caseOf(inst, mode, tail),
        else => {},
    }
    const v = try f.evalInner(inst, mode);
    if (mode == .value) try f.leak(v, inst);
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

/// A function value that asks its caller for `own` goes where no rule
/// follows it: the checker cannot answer for its callers.
fn leak(f: *Frame, v: Val, inst: u32) Error!void {
    const n = f.nodes.items[v];
    const c: *const Contract = switch (n.tag) {
        .closure => f.codes.items[n.a].contract,
        .fnref => (try f.m.declContract(.{ n.a, n.b })) orelse return,
        else => return,
    };
    const own = if (n.tag == .closure) f.codes.items[n.a].own_params else c.arity;
    if (!writesOwn(c, own)) return;
    try f.m.addRefusal(f, inst, .call, "a function that writes its parameter goes where the checker does not follow it");
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

/// A local of an enclosing frame: a root of this one.
fn capture(f: *Frame, local: u32) Error!Val {
    const m = f.m;
    // A local that no frame has bound yet (a later local function): nothing is known of it.
    if (m.lframe[f.d.locals_start + local] == 0 or !f.is_lambda) return v_shared;
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
            // A local function that names itself, while it is walked.
            if (m.lframe[l] == none) return v_none;
            if (m.lframe[l] != f.id) return f.capture(data.lhs);
            return m.lv[l];
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
            return f.smearVal(try m.placeOfInst(inst), &.{v});
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
                    else => false,
                };
                if (kept) try f.escape(v, inst) else try f.readAll(v, inst);
            }
            return f.unknownResult(inst);
        },
        else => return v_shared,
    }
}

/// A constructor used as a function value: its contract says that the
/// result's argument `k` is parameter `k`, location for location.
fn ctorValue(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const info = m.ctorInfo(inst) orelse return v_none;
    if (info.arity == 0) return v_none;
    const ty = m.typeOfInst(inst);
    const ft = m.fnType(ty) orelse return v_none;
    const pvars = m.in.store.vars(ft.params);
    if (pvars.len != info.arity) return v_none;
    const rplace = try m.placeOf(ft.result.toOptional());
    if (m.places.kind(rplace) != .ctor or try f.layoutLen(rplace) == 0) return v_none;
    if (m.code_contract[inst] == null) {
        const params = try f.gpa.alloc(PlaceId, pvars.len);
        for (params, pvars) |*p, v| p.* = try m.placeOf(v.toOptional());
        const c = try m.emptyContract(params, rplace);
        const lists = try f.gpa.alloc(std.ArrayList(Src), c.res.len);
        for (lists) |*l| l.* = .empty;
        for (0..info.arity) |k| {
            const pr = (try m.loc.proj(rplace, try m.ctorStep(info.ordinal, @intCast(k)))) orelse continue;
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
            if (@backingInt(def.params_end) != @backingInt(def.params_start)) {
                // A local function: its own frame; the local names it inside too.
                const params = m.bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Inst.Index);
                const v = try f.codeValue(b, params, data.rhs, m.typeOfLocal(f.d, def.local), def.local);
                f.bindLocal(def.local, v);
                return;
            }
            f.bindLocal(def.local, try f.eval(data.rhs, .bind, false));
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

// ---- function values -------------------------------------------------------------------

/// Walk the code at `inst` in its own frame, to its contract; the value is a closure over its captures.
fn codeValue(f: *Frame, inst: u32, params: []const Inst.Index, body: u32, ty: Var.Optional, self_local: u32) Error!Val {
    const m = f.m;
    const fnt = m.fnType(ty);
    var rounds: u32 = 0;
    var cap_locals: []const u32 = &.{};
    while (true) : (rounds += 1) {
        const mark = m.lines.items.len;
        var child = try Frame.init(m, f, f.decl, true, inst);
        child.own_params = @intCast(params.len);
        if (child.depth > 200) {
            f.failed = true;
            return v_shared;
        }
        if (self_local != none) {
            // The function names itself: a call of it reads its contract so far.
            m.lv[f.d.locals_start + self_local] = v_none;
            m.lframe[f.d.locals_start + self_local] = none;
        }
        const pvars: []const Var = if (fnt) |ft| m.in.store.vars(ft.params) else &.{};
        for (params, 0..) |p, k| {
            const place = if (k < pvars.len) try m.placeOf(pvars[k].toOptional()) else m.var_place;
            try child.addParam(place, p.int(), if (k < pvars.len) pvars[k].toOptional() else .none);
        }
        try child.walkBody(body);
        const rplace = if (fnt) |ft| try m.placeOf(ft.result.toOptional()) else m.var_place;
        const c = try child.finish(rplace);
        if (child.failed) f.failed = true;
        cap_locals = try f.gpa.dupe(u32, child.cap_locals.items);
        const old = m.code_contract[inst];
        const joined = if (old) |o| try CMod.join(m.arena, o, c) else c;
        const changed = if (old) |o| !CMod.eql(o, joined) else true;
        m.code_contract[inst] = joined;
        // A local function that calls itself is walked again until its contract holds.
        if (!changed or !child.self_called or rounds > 16) {
            if (rounds > 16) f.failed = true;
            break;
        }
        m.lines.shrinkRetainingCapacity(mark);
    }
    const c = m.code_contract[inst].?;
    // The captured locals, as this frame has them: the closure holds them.
    var tmp: std.ArrayList(Val) = .empty;
    defer tmp.deinit(f.gpa);
    for (cap_locals) |l| {
        const abs = f.d.locals_start + l;
        try tmp.append(f.gpa, if (m.lframe[abs] != f.id) try f.capture(l) else m.lv[abs]);
    }
    const start: u32 = @intCast(f.lists.items.len);
    try f.lists.appendSlice(f.gpa, tmp.items);
    try f.codes.append(f.gpa, .{ .contract = c, .caps = start, .ncaps = @intCast(cap_locals.len), .inst = inst, .own_params = @intCast(params.len) });
    return f.node(.{ .tag = .closure, .place = try m.placeOf(ty), .a = @intCast(f.codes.items.len - 1) });
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
    // The function parameters.
    const fns = try m.arena.alloc(?*const CMod.Fn, arity);
    @memset(fns, null);
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
        for (flags[off[idx]..off[idx + 1]]) |*x| x.* |= flag_r;
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
            const info = m.ctorInfo(callee);
            var tmp: std.ArrayList(Kid) = .empty;
            defer tmp.deinit(f.gpa);
            var vals: std.ArrayList(Val) = .empty;
            defer vals.deinit(f.gpa);
            for (args, 0..) |a, k| {
                const v = try f.ev(a.int());
                try vals.append(f.gpa, v);
                if (info) |ci| try tmp.append(f.gpa, .{ .step = (try m.ctorStep(ci.ordinal, @intCast(k))).word(), .val = v });
            }
            if (info == null or m.places.kind(place) != .ctor) return f.smearVal(place, vals.items);
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
                .none => {
                    // A local function that calls itself, while it is walked.
                    if (m.tags[callee] == .local and m.lframe[f.d.locals_start + m.datas[callee].lhs] == none) {
                        if (f.selfCode(m.datas[callee].lhs)) |c| code = c;
                    }
                },
                else => {},
            }
        },
    }
    if (code) |c| if (c.contract.entry and args.len == 1) return f.entryCall(inst, args[0].int());
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    for (args, 0..) |a, k| {
        const is_fn = if (code) |c| k < c.contract.arity and c.contract.fns[k] != null and !c.contract.fns[k].?.lost else false;
        try vals.append(f.gpa, try f.eval(a.int(), if (is_fn) .fn_arg else .value, false));
    }
    if (code) |c| return f.apply(inst, callee, c, vals.items, args);
    if (fn_root != none) return f.callParam(inst, callee, fn_root, vals.items, args);
    // An unknown function: it can keep each argument, and its answer has no claim.
    for (vals.items) |v| try f.escape(v, inst);
    if (callee_val != v_none) try f.escape(callee_val, inst);
    return f.unknownResult(inst);
}

/// The code of the local function `local`, while one of its own frames is walked.
fn selfCode(f: *Frame, local: u32) ?Code {
    const m = f.m;
    var at: ?*Frame = f;
    while (at) |fr| : (at = fr.parent) {
        if (!fr.is_lambda) break;
        if (m.tags[fr.code_inst] != .let_def) continue;
        const def = m.bir.extraData(@fromBackingInt(m.datas[fr.code_inst].lhs), Bir.LetDef);
        if (def.local != local) continue;
        fr.self_called = true;
        const c = m.code_contract[fr.code_inst] orelse return null;
        // Only the own parameters are known here: a capture is the same value in each call.
        if (c.arity != fr.own_params) return null;
        return .{ .contract = c, .inst = fr.code_inst, .own_params = fr.own_params };
    }
    return null;
}

fn methodCall(f: *Frame, inst: u32) Error!Val {
    const m = f.m;
    const data = m.datas[inst];
    const mc = m.bir.extraData(@fromBackingInt(data.rhs), Bir.MethodCall);
    const args = m.bir.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
    var vals: std.ArrayList(Val) = .empty;
    defer vals.deinit(f.gpa);
    try vals.append(f.gpa, try f.ev(data.lhs));
    for (args) |a| try vals.append(f.gpa, try f.ev(a.int()));
    try f.evidence(inst);
    // `==`, `<` and their kin call a type's `eq` and `compare`, which only
    // read (language.md §6.5); `Check` refuses one that does more.
    const name = m.symbolText(mc.name);
    if (mc.origin != .none or std.mem.eql(u8, name, "compare") or std.mem.eql(u8, name, "eq")) {
        for (vals.items) |v| try f.readAll(v, inst);
        return f.unknownResult(inst);
    }
    if (m.methodTarget(inst)) |t| {
        if (try m.declContract(t)) |c| {
            if (c.arity == vals.items.len) {
                var all: std.ArrayList(Inst.Index) = .empty;
                defer all.deinit(f.gpa);
                try all.append(f.gpa, @fromBackingInt(data.lhs));
                try all.appendSlice(f.gpa, args);
                return f.apply(inst, inst, .{ .contract = c, .decl = t, .own_params = c.arity }, vals.items, all.items);
            }
        }
    }
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
/// (a function writes a part of what a type variable stands for).
fn argLeaves(f: *Frame, v: Val, sig: u32, se: u32, suffix: []const u64, out: *std.ArrayList(Atom)) Error!bool {
    const m = f.m;
    const n = f.nodes.items[v];
    switch (n.tag) {
        .none, .fnref => return false,
        .shared => {
            try out.append(f.gpa, shared_atom);
            return false;
        },
        .closure, .smear => return f.leaves(v, 0, out),
        else => {},
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
            for (m.loc.layoutEntries(own), 0..) |oe, k| if (oe.loc == wl and cov[k] == se) {
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
    for (0..code.ncaps) |k| try all.append(f.gpa, f.lists.items[code.caps + k]);
    if (all.items.len != c.arity) {
        // A partial or an over-application: no rule follows it.
        for (all.items) |v| try f.escape(v, inst);
        if (c.writes()) try m.addRefusal(f, inst, .call, "a function that writes its parameter is not called with all its arguments");
        return f.unknownResult(inst);
    }
    const args = all.items;
    // A function that answers its one parameter as it is (`Js.from`, `Js.to`,
    // `identity`): the value keeps its shape through a type that has none.
    if (c.arity == 1 and c.fns[0] == null and c.res.len == 1 and c.res[0].len == 1 and c.flags.len == 1 and c.flags[0] & (flag_w | flag_e) == 0) {
        const s = c.res[0][0];
        const pe = m.loc.layoutEntries(c.layouts[0])[0];
        const re = m.loc.layoutEntries(c.layouts[1])[0];
        if (s.kind == .param and s.a == 0 and s.e == 0 and pe.loc == 0 and re.loc == 0 and pe.kind.wide() and re.kind.wide()) {
            try f.readBy(args[0], inst, c.layouts[0], c.flags, false);
            return args[0];
        }
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
                const dup = try f.argLeaves(args[j], sig, @intCast(se), &.{}, &f.atoms);
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
                _ = try f.argLeaves(args[j], sig, @intCast(se), &.{}, &f.atoms);
                try f.noteEscape(start, inst);
            }
        }
    }
    // The functions it is handed.
    for (0..c.arity) |j| {
        const fnc = c.fns[j] orelse continue;
        try f.handFunction(inst, callee, c, fnc, j, args, arg_insts, others);
    }
    // What it reads.
    for (0..c.arity) |j| try f.readBy(args[j], inst, c.layouts[j], c.flags[c.off[j]..c.off[j + 1]], c.fns[j] != null);
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
            for (c.res, 0..) |srcs, ri| try f.expandSrcs(c, srcs, args, c.layouts[c.arity], @intCast(ri), layout, @intCast(e), &st, 0);
        } else try f.expandSrcs(c, c.res[cr], args, c.layouts[c.arity], cr, layout, @intCast(e), &st, 0);
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
    return f.rootVal(root);
}

const SrcState = struct {
    fresh: bool = false,
    shared: bool = false,
    dup: bool = false,
    written: bool = false,
    inst: u32 = none,
    /// The labels of the caller's result entry below the callee's result entry in work.
    suffix: []const u64 = &.{},
    /// The answers in work: `(parameter of the callee, result entry of the known function there)`.
    /// An answer that comes back to itself adds no cell (the least fixed point).
    seen: [24][2]u32 = undefined,
    nseen: u32 = 0,
    /// Each part of the answer is asked for, not the one at `suffix`.
    whole: bool = false,
    fn visit(st: *SrcState, a: u32, k: u32) enum { new, old, full } {
        for (st.seen[0..st.nseen]) |x| if (x[0] == a and x[1] == k) return .old;
        if (st.nseen == st.seen.len) return .full;
        st.seen[st.nseen] = .{ a, k };
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
fn expandSrcs(f: *Frame, c: *const Contract, srcs: []const Src, args: []const Val, rsig: u32, cr: u32, rlayout: u32, e: u32, st: *SrcState, depth: u32) Error!void {
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
                // is not in the callee's other sources (`expandAnswer` says
                // `dup` when the callee could hand a cell twice).
                try f.expandAnswer(c, s, args, st, depth);
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
    if (!(pentry.kind.wide() and rentry.kind.wide())) return f.argLeaves(v, psig, pe, &.{}, &f.atoms);
    const rloc = m.loc.layoutEntries(rlayout)[e].loc;
    // The fallback cover: the caller's entry is not below the callee's.
    if (!m.loc.isPrefix(rentry.loc, rloc)) return f.argLeaves(v, psig, pe, &.{}, &f.atoms);
    var labels: std.ArrayList(u64) = .empty;
    defer labels.deinit(f.gpa);
    try m.loc.labels(rloc, &labels, f.gpa);
    const skip = m.loc.loc_depth.items[rentry.loc];
    return f.argLeaves(v, psig, pe, labels.items[skip..], &f.atoms);
}

/// The frame's own function parameter that `v` is, or `none`.
fn ownFnRoot(f: *Frame, v: Val) u32 {
    const n = f.nodes.items[v];
    if (n.tag != .ref) return none;
    const r = f.roots.items[n.a];
    return if ((r.kind == .param or r.kind == .capture) and n.b == r.path) n.a else none;
}

/// The answer atoms of the frame's own function parameter at root `root`, for the answer entry `ae` of layout `alayout`.
fn ownAnswer(f: *Frame, root: u32, alayout: u32, ae: u32, st: *SrcState) Error!void {
    const di = (try f.draftOf(root, null)) orelse {
        st.shared = true;
        return;
    };
    const ar = f.roots.items[f.answers.items[try f.answerAt(di, st.inst)].root];
    const root_id = f.answers.items[try f.answerAt(di, st.inst)].root;
    const dr = f.drafts.items[di];
    const cov = try f.m.loc.cover(alayout, dr.layouts[dr.arity]);
    for (cov, 0..) |cv, k| if (Loc.hits(cv, ae)) try f.atoms.append(f.gpa, .{ .root = root_id, .path = ar.path, .e = @intCast(k) });
}

/// No rule follows this answer. It has no claim, and it can hold a cell of
/// each argument of the call: what a function captured is a cell of the
/// argument that the function is. A location with no claim keeps what it
/// can hold (report 111 §3.5).
fn lostAnswer(f: *Frame, args: []const Val, st: *SrcState) Error!void {
    st.shared = true;
    for (args) |a| _ = try f.allLeaves(a, &f.atoms);
}

/// The answer of the function at parameter `s.a`: what the known function there answers.
fn expandAnswer(f: *Frame, c: *const Contract, s: Src, args: []const Val, st: *SrcState, depth: u32) Error!void {
    const m = f.m;
    if (s.a >= args.len) return f.lostAnswer(args, st);
    const v = args[s.a];
    const fnc = c.fns[s.a] orelse return f.lostAnswer(args, st);
    const code = (try f.codeOf(v)) orelse {
        // A function the frame does not know: the frame's own function
        // parameter answers through its own contract, anything else has no claim.
        const root = f.ownFnRoot(v);
        if (root == none) try f.lostAnswer(args, st) else try f.ownAnswer(root, fnc.layouts[fnc.arity], s.e, st);
        return;
    };
    if (depth > 8 or code.own_params != fnc.arity) return f.lostAnswer(args, st);
    const lc = code.contract;
    const cov = try m.loc.cover(fnc.layouts[fnc.arity], lc.layouts[lc.arity]);
    // The known function's result entry at the same part below the answer, when it has one.
    var want: ?u32 = m.loc.layoutEntries(fnc.layouts[fnc.arity])[s.e].loc;
    for (st.suffix) |l| {
        want = m.loc.find(want.?, l);
        if (want == null) break;
    }
    var exact = false;
    if (!st.whole) if (want) |wl| for (m.loc.layoutEntries(lc.layouts[lc.arity]), 0..) |re_e, re| if (re_e.loc == wl and Loc.hits(cov[re], s.e)) {
        exact = true;
    };
    var psuffix: std.ArrayList(u64) = .empty;
    defer psuffix.deinit(f.gpa);
    for (cov, 0..) |cv, k| {
        if (!Loc.hits(cv, s.e)) continue;
        if (exact and m.loc.layoutEntries(lc.layouts[lc.arity])[k].loc != want.?) continue;
        switch (st.visit(s.a, @intCast(k))) {
            .new => {},
            // In work already: it adds no cell.
            .old => continue,
            .full => return f.lostAnswer(args, st),
        }
        for (lc.res[k]) |ls| switch (ls.kind) {
            .fresh => st.fresh = true,
            .shared => st.shared = true,
            .answer => {
                // The answer of a function that the known function captured: the frame's own, or no claim.
                if (ls.a < code.own_params or ls.a - code.own_params >= code.ncaps) {
                    try f.lostAnswer(args, st);
                    continue;
                }
                const root = f.ownFnRoot(f.lists.items[code.caps + ls.a - code.own_params]);
                const lf = lc.fns[ls.a];
                if (root == none or lf == null) try f.lostAnswer(args, st) else try f.ownAnswer(root, lf.?.layouts[lf.?.arity], ls.e, st);
            },
            .param => {
                if (ls.a >= code.own_params) {
                    // A captured value in the answer: each run answers the
                    // same cell, so no claim. The answer still holds it.
                    st.shared = true;
                    if (ls.a - code.own_params < code.ncaps) {
                        _ = try f.argLeaves(f.lists.items[code.caps + ls.a - code.own_params], lc.layouts[ls.a], ls.e, &.{}, &f.atoms);
                    } else try f.lostAnswer(args, st);
                    continue;
                }
                // What the callee hands that parameter.
                const pcov = try m.loc.cover(fnc.layouts[ls.a], lc.layouts[ls.a]);
                const fe = pcov[ls.e];
                if (fe >= Loc.all) {
                    try f.lostAnswer(args, st);
                    continue;
                }
                // The callee can hand one cell to two calls: two answers can be that cell.
                if (!fnc.free[fnc.off[ls.a] + fe]) st.dup = true;
                for (fnc.supply[fnc.off[ls.a] + fe]) |ss| switch (ss.kind) {
                    .fresh => st.fresh = true,
                    .shared => st.shared = true,
                    .answer => {
                        // The callee hands the function an answer: of this
                        // function at another part, or of another function.
                        // What that answer holds, this one can hold.
                        try f.suffixOf(m.loc.layoutEntries(lc.layouts[ls.a])[ls.e].loc, m.loc.layoutEntries(fnc.layouts[ls.a])[fe].loc, &psuffix);
                        const outer = st.suffix;
                        const kept = try f.gpa.dupe(u64, psuffix.items);
                        st.suffix = kept;
                        try f.expandAnswer(c, ss, args, st, depth + 1);
                        st.suffix = outer;
                    },
                    .param => {
                        if (ss.a >= args.len) {
                            try f.lostAnswer(args, st);
                            continue;
                        }
                        // The part of the argument that the function's parameter entry is.
                        try f.suffixOf(m.loc.layoutEntries(lc.layouts[ls.a])[ls.e].loc, m.loc.layoutEntries(fnc.layouts[ls.a])[fe].loc, &psuffix);
                        const at = f.atoms.items.len;
                        if (try f.argLeaves(args[ss.a], c.layouts[ss.a], ss.e, psuffix.items, &f.atoms)) st.dup = true;
                        if (c.flags[c.off[ss.a] + ss.e] & (flag_w | flag_s) != 0) f.oldNames(at, st);
                    },
                };
            },
        };
    }
}

fn codeOf(f: *Frame, v: Val) Error!?Code {
    const n = f.nodes.items[v];
    return switch (n.tag) {
        .closure => f.codes.items[n.a],
        .fnref => blk: {
            const c = (try f.m.declContract(.{ n.a, n.b })) orelse break :blk null;
            break :blk .{ .contract = c, .decl = .{ n.a, n.b }, .own_params = c.arity };
        },
        else => null,
    };
}

/// The callee hands the function at parameter `j` what `fnc` says: a known
/// function's writes are judged against it, here.
fn handFunction(f: *Frame, inst: u32, callee: u32, c: *const Contract, fnc: *const CMod.Fn, j: usize, args: []const Val, arg_insts: []const Inst.Index, others: []const Other) Error!void {
    const m = f.m;
    const v = args[j];
    if (v == v_none) return;
    // The callee lets the function's answer escape: each cell that the answer can hold escapes here.
    if (fnc.ans_escapes) try f.escapeAnswer(inst, c, fnc, j, args);
    const code = (try f.codeOf(v)) orelse {
        const root = f.ownFnRoot(v);
        if (root != none) return f.passFunction(inst, c, fnc, root, args, others);
        // An unknown function: it can keep what it is handed.
        try f.escapeSupplies(inst, c, fnc, args);
        if (fnc.lost) try f.escape(v, inst);
        if (fnc.rewrites) try m.addRefusal(f, inst, .supply, "the callee changes a value after it handed it to a function that the checker does not know");
        return;
    };
    const lc = code.contract;
    if (fnc.lost or code.own_params != fnc.arity) {
        if (writesOwn(lc, code.own_params)) try m.addRefusal(f, inst, .call, "a function that writes its parameter goes where the checker does not follow it");
        try f.escapeSupplies(inst, c, fnc, args);
        // It can run at any later time: what it captured is held from here on.
        try f.escape(v, inst);
        return;
    }
    if (fnc.rewrites and keepsOwn(lc, code.own_params)) try m.addRefusal(f, inst, .supply, "the function keeps a value that the callee changes later");
    for (0..fnc.arity) |k| {
        const pcov = try m.loc.cover(fnc.layouts[k], lc.layouts[k]);
        const n = lc.off[k + 1] - lc.off[k];
        for (0..n) |le| {
            const fl = lc.flags[lc.off[k] + le];
            if (fl & (flag_w | flag_e) == 0) continue;
            const fe: u32 = if (pcov[le] >= Loc.all) none else pcov[le];
            if (fl & flag_w != 0) {
                var seen: [16]u32 = undefined;
                var nseen: usize = 0;
                try f.supplyOwn(.{ .inst = inst, .callee = callee, .c = c, .fnc = fnc, .code = code, .args = args, .arg_insts = arg_insts, .others = others, .fn_arg = j }, @intCast(k), @intCast(le), &seen, &nseen);
            }
            if (fl & flag_e != 0 and fe != none) {
                for (fnc.supply[fnc.off[k] + fe]) |ss| if (ss.kind == .param and ss.a < args.len) {
                    const start: u32 = @intCast(f.atoms.items.len);
                    _ = try f.argLeaves(args[ss.a], c.layouts[ss.a], ss.e, &.{}, &f.atoms);
                    try f.noteEscape(start, inst);
                };
            }
        }
    }
    // The functions that the known function captured and calls: the frame's own are handed on.
    for (0..code.ncaps) |k| {
        const lf = lc.fns[code.own_params + k] orelse continue;
        const cv = f.lists.items[code.caps + k];
        const root = f.ownFnRoot(cv);
        if (root != none) {
            try f.throughClosure(inst, c, fnc, code, lf, root, j, args, others);
            continue;
        }
        // Another function that the known function captured and calls. No
        // rule composes its contract with what it is handed there. So it
        // cannot write, and what it can keep is held from here on.
        var keeps = true;
        if (try f.codeOf(cv)) |cc| {
            if (writesOwn(cc.contract, cc.own_params)) try m.addRefusal(f, inst, .call, "a function that writes its parameter is called by a function that goes to another function");
            keeps = keepsOwn(cc.contract, cc.own_params);
        }
        if (!keeps) continue;
        if (lf.rewrites or fnc.rewrites) try m.addRefusal(f, inst, .supply, "a function that can keep a value is handed one that changes later");
        for (args) |a| try f.escape(a, inst);
    }
}

/// The known function `s.code` answers its parameter `(a, e)`, the callee
/// hands that answer back, and the function writes it then. A function that
/// `s.code` handed the cell to must not keep it.
fn handedBack(f: *Frame, s: Supply, a: u32, e: u32) Error!void {
    const m = f.m;
    const lc = s.code.contract;
    for (lc.fns, 0..) |lfo, jj| {
        const lf = lfo orelse continue;
        var handed = false;
        for (lf.supply) |srcs| for (srcs) |x| if (x.kind == .param and x.a == a and x.e == e) {
            handed = true;
        };
        if (!handed) continue;
        if (jj < s.code.own_params or jj - s.code.own_params >= s.code.ncaps) {
            try m.addRefusal(f, s.inst, .supply, "the function hands on a value that it answers, and the callee hands it back");
            continue;
        }
        const cv = f.lists.items[s.code.caps + jj - s.code.own_params];
        const root = f.ownFnRoot(cv);
        if (root != none) {
            if (try f.draftOf(root, null)) |di| {
                f.drafts.items[di].rewrites = true;
                continue;
            }
        } else if (try f.codeOf(cv)) |cc| {
            if (!keepsOwn(cc.contract, cc.own_params)) continue;
        }
        try m.addRefusal(f, s.inst, .supply, "the function hands a value to a function that can keep it, answers it, and the callee hands it back");
    }
}

/// Each cell that the answer of the function at parameter `j` can hold escapes at the call `inst`.
fn escapeAnswer(f: *Frame, inst: u32, c: *const Contract, fnc: *const CMod.Fn, j: usize, args: []const Val) Error!void {
    const n = f.m.loc.layouts.items[fnc.layouts[fnc.arity]].len;
    const start: u32 = @intCast(f.atoms.items.len);
    var st: SrcState = .{ .inst = inst, .whole = true };
    for (0..n) |ae| try f.expandAnswer(c, .{ .kind = .answer, .a = @intCast(j), .e = @intCast(ae) }, args, &st, 0);
    try f.noteEscape(start, inst);
}

fn escapeSupplies(f: *Frame, inst: u32, c: *const Contract, fnc: *const CMod.Fn, args: []const Val) Error!void {
    for (fnc.supply) |ss| for (ss) |s| if (s.kind == .param and s.a < args.len) {
        const start: u32 = @intCast(f.atoms.items.len);
        _ = try f.argLeaves(args[s.a], c.layouts[s.a], s.e, &.{}, &f.atoms);
        try f.noteEscape(start, inst);
    };
}

const Supply = struct {
    inst: u32,
    callee: u32,
    c: *const Contract,
    fnc: *const CMod.Fn,
    code: Code,
    args: []const Val,
    arg_insts: []const Inst.Index,
    others: []const Other,
    fn_arg: usize,
};

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

/// The known function `s.code` writes its parameter `k` at its entry `le`:
/// every source of what the callee hands there must be `own`.
fn supplyOwn(f: *Frame, s: Supply, k: u32, le: u32, seen: *[16]u32, nseen: *usize) Error!void {
    const m = f.m;
    const lc = s.code.contract;
    const pcov = try m.loc.cover(s.fnc.layouts[k], lc.layouts[k]);
    const fe: u32 = if (pcov[le] >= Loc.all) none else pcov[le];
    if (fe == none or !s.fnc.free[s.fnc.off[k] + fe]) {
        try m.addRefusal(f, s.inst, .supply, "the function writes a parameter that the callee reads again or does not hand as its own");
        return;
    }
    const key = (k << 16) | le;
    for (seen[0..nseen.*]) |x| if (x == key) return;
    if (nseen.* == seen.len) {
        try m.addRefusal(f, s.inst, .supply, "the supply of a function parameter is too deep to follow");
        return;
    }
    seen[nseen.*] = key;
    nseen.* += 1;
    // The part below the callee's entry that the function writes.
    var suffix: std.ArrayList(u64) = .empty;
    defer suffix.deinit(f.gpa);
    try f.suffixOf(m.loc.layoutEntries(lc.layouts[k])[le].loc, m.loc.layoutEntries(s.fnc.layouts[k])[fe].loc, &suffix);
    for (s.fnc.supply[s.fnc.off[k] + fe]) |src| switch (src.kind) {
        .fresh => {},
        .shared => try m.addRefusal(f, s.inst, .supply, "the callee hands the function a value that it does not own"),
        .param => {
            if (src.a >= s.args.len) {
                try m.addRefusal(f, s.inst, .supply, "the callee hands the function a captured value");
                continue;
            }
            const w: u32 = @intCast(f.atoms.items.len);
            const dup = try f.argLeaves(s.args[src.a], s.c.layouts[src.a], src.e, suffix.items, &f.atoms);
            if (f.atoms.items.len == w) continue;
            var loc = m.loc.layoutEntries(s.c.layouts[src.a])[src.e].loc;
            for (suffix.items) |l| loc = try m.loc.extend(loc, @bitCast(l));
            try f.demand(w, .{
                .point = s.inst,
                .callee_inst = s.callee,
                .base_inst = if (src.a < s.arg_insts.len) s.arg_insts[src.a].int() else none,
                .loc = loc,
                .others = s.others,
                .arg = src.a,
                .se = src.e,
                .suffix = suffix.items,
                .dup = dup and !m.loc.layoutEntries(s.c.layouts[src.a])[src.e].single,
                .kind = .callsite,
            });
        },
        .answer => {
            // The function's own answer comes back to it: what it answers at
            // the written part must be `own`.
            if (src.a != s.fn_arg) {
                try m.addRefusal(f, s.inst, .supply, "the callee hands the function the answer of another function");
                continue;
            }
            // The answer comes back as the function's parameter, whose
            // locations are apart. So the answer must hold each cell once.
            if (lc.nonlinear) {
                try m.addRefusal(f, s.inst, .supply, "the function can answer one cell at two places, and the callee hands the answer back");
                continue;
            }
            const rcov = try m.loc.cover(s.fnc.layouts[s.fnc.arity], lc.layouts[lc.arity]);
            var want: ?u32 = m.loc.layoutEntries(s.fnc.layouts[s.fnc.arity])[src.e].loc;
            for (suffix.items) |l| {
                want = m.loc.find(want.?, l);
                if (want == null) break;
            }
            var exact = false;
            if (want) |wl| for (m.loc.layoutEntries(lc.layouts[lc.arity]), 0..) |re_e, re| if (re_e.loc == wl and Loc.hits(rcov[re], src.e)) {
                exact = true;
            };
            for (rcov, 0..) |cv, re| {
                if (!Loc.hits(cv, src.e)) continue;
                if (exact and m.loc.layoutEntries(lc.layouts[lc.arity])[re].loc != want.?) continue;
                for (lc.res[re]) |ls| switch (ls.kind) {
                    .fresh => {},
                    .shared, .answer => try m.addRefusal(f, s.inst, .supply, "the function answers a value that it does not own, and the callee hands it back"),
                    .param => {
                        if (ls.a >= s.code.own_params) {
                            try m.addRefusal(f, s.inst, .supply, "the function answers a captured value, and the callee hands it back");
                            continue;
                        }
                        if (lc.flags[lc.off[ls.a] + ls.e] & flag_e != 0) {
                            try m.addRefusal(f, s.inst, .supply, "the function lets a value escape and answers it, and the callee hands it back");
                            continue;
                        }
                        try f.handedBack(s, ls.a, ls.e);
                        try f.supplyOwn(s, ls.a, ls.e, seen, nseen);
                    },
                };
            }
        },
    };
}

// ---- the frame's own function parameters ---------------------------------------------------

/// The draft of the function at root `root`, made from its type on first use.
fn draftOf(f: *Frame, root: u32, callee_inst: ?u32) Error!?u32 {
    const m = f.m;
    for (f.drafts.items, 0..) |dr, i| if (dr.root == root) return @intCast(i);
    const r = f.roots.items[root];
    var fnt = if (callee_inst) |ci| m.fnType(m.typeOfInst(ci)) else null;
    if (fnt == null and r.index < f.param_ty.items.len) fnt = m.fnType(f.param_ty.items[r.index]);
    const ft = fnt orelse return null;
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
fn answerAt(f: *Frame, di: u32, inst: u32) Error!u32 {
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
    const ai = try f.answerAt(di, point);
    for (w..end) |i| try f.answers.items[ai].base.append(f.gpa, f.atoms.items[i]);
    if (dup) f.drafts.items[di].free[slot] = false;
    // Could the function write here: the check of a write, with no line.
    try f.demand(w, .{ .point = point, .op = .supply, .kind = if (send_callee != none) .send else .writer, .callee_inst = send_callee, .base_inst = send_base, .others = others, .arg = arg, .se = se, .draft = di, .slot = slot, .skip = f.answers.items[ai].root, .send = send_callee != none, .dup = dup and send_callee != none });
}

/// No rule follows what the function at draft `di` is handed at `slot` in the
/// call `point`: no claim, and it can be a cell of each of `vals`. So the
/// function's answer can hold them, and the contract says so.
fn supplyLost(f: *Frame, di: u32, slot: u32, point: u32, vals: []const Val) Error!void {
    try f.drafts.items[di].supply[slot].append(f.gpa, Src.shared);
    f.drafts.items[di].free[slot] = false;
    const w = f.atoms.items.len;
    for (vals) |v| _ = try f.allLeaves(v, &f.atoms);
    try f.uniqueTail(&f.atoms, w);
    const end = f.atoms.items.len;
    var srcs: std.ArrayList(Src) = .empty;
    defer srcs.deinit(f.gpa);
    for (w..end) |i| try f.atomSrcs(f.atoms.items[i], &srcs, 0);
    try f.drafts.items[di].supply[slot].appendSlice(f.gpa, srcs.items);
    const ai = try f.answerAt(di, point);
    try f.answers.items[ai].base.appendSlice(f.gpa, f.atoms.items[w..end]);
    f.atoms.shrinkRetainingCapacity(w);
}

/// A call of the frame's own function parameter at root `root`.
fn callParam(f: *Frame, inst: u32, callee: u32, root: u32, vals: []const Val, arg_insts: []const Inst.Index) Error!Val {
    const m = f.m;
    const di = (try f.draftOf(root, callee)) orelse {
        for (vals) |v| try f.escape(v, inst);
        return f.unknownResult(inst);
    };
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
    const ai = try f.answerAt(di, inst);
    try f.answers.items[ai].base.append(f.gpa, .{ .root = root, .path = f.roots.items[root].path, .e = 0 });
    return f.rootVal(f.answers.items[ai].root);
}

/// The frame hands its own function parameter `root` to a callee that has a
/// contract for it: what the callee hands it, this frame hands it.
fn passFunction(f: *Frame, inst: u32, c: *const Contract, fnc: *const CMod.Fn, root: u32, args: []const Val, others: []const Other) Error!void {
    const m = f.m;
    const di = (try f.draftOf(root, null)) orelse {
        try f.escapeSupplies(inst, c, fnc, args);
        return;
    };
    if (fnc.lost or f.drafts.items[di].arity != fnc.arity) {
        f.drafts.items[di].lost = true;
        try f.escapeSupplies(inst, c, fnc, args);
        return;
    }
    if (fnc.called) f.drafts.items[di].called = true;
    if (fnc.rewrites) f.drafts.items[di].rewrites = true;
    for (0..fnc.arity) |k| {
        const cov = try m.loc.cover(fnc.layouts[k], f.drafts.items[di].layouts[k]);
        for (cov, 0..) |fe, me| {
            const slot = f.drafts.items[di].off[k] + @as(u32, @intCast(me));
            if (fe >= Loc.all) {
                try f.supplyLost(di, slot, inst, args);
                continue;
            }
            if (!fnc.free[fnc.off[k] + fe]) f.drafts.items[di].free[slot] = false;
            for (fnc.supply[fnc.off[k] + fe]) |s| switch (s.kind) {
                .fresh, .shared => try f.drafts.items[di].supply[slot].append(f.gpa, s),
                .answer => {
                    // The answer of the function the callee was handed at `s.a`: this one's when it is this one.
                    const av = if (s.a < args.len) args[s.a] else v_shared;
                    if (f.ownFnRoot(av) == root) {
                        const acov = try m.loc.cover(fnc.layouts[fnc.arity], f.drafts.items[di].layouts[fnc.arity]);
                        for (acov, 0..) |cv, ae| if (Loc.hits(cv, s.e)) try f.drafts.items[di].supply[slot].append(f.gpa, .{ .kind = .answer, .a = @intCast(f.roots.items[root].index), .e = @intCast(ae) });
                    } else try f.supplyLost(di, slot, inst, args);
                },
                .param => {
                    if (s.a >= args.len) {
                        try f.supplyLost(di, slot, inst, args);
                        continue;
                    }
                    const w: u32 = @intCast(f.atoms.items.len);
                    const dup = try f.argLeaves(args[s.a], c.layouts[s.a], s.e, &.{}, &f.atoms);
                    try f.supplyAtoms(di, slot, w, inst, others, s.a, s.e, dup);
                },
            };
        }
    }
}

/// The known function `code`, handed to the callee at parameter `j`, calls a
/// function that it captured: the frame's own function parameter at `root`.
/// What `code` hands it (`lf`), in terms of what the callee hands `code`.
fn throughClosure(f: *Frame, inst: u32, c: *const Contract, fnc: *const CMod.Fn, code: Code, lf: *const CMod.Fn, root: u32, j: usize, args: []const Val, others: []const Other) Error!void {
    const m = f.m;
    const lc = code.contract;
    const di = (try f.draftOf(root, null)) orelse return;
    if (lf.lost or f.drafts.items[di].arity != lf.arity or code.own_params != fnc.arity) {
        f.drafts.items[di].lost = true;
        return;
    }
    if (lf.called) f.drafts.items[di].called = true;
    // What the callee changes after it handed it to `code`, `code` can have handed on.
    if (lf.rewrites or fnc.rewrites) f.drafts.items[di].rewrites = true;
    const my_index: u16 = @intCast(f.roots.items[root].index);
    for (0..lf.arity) |k| {
        const cov = try m.loc.cover(lf.layouts[k], f.drafts.items[di].layouts[k]);
        for (cov, 0..) |le, me| {
            const slot = f.drafts.items[di].off[k] + @as(u32, @intCast(me));
            if (le >= Loc.all) {
                try f.supplyLost(di, slot, inst, args);
                continue;
            }
            if (!lf.free[lf.off[k] + le]) f.drafts.items[di].free[slot] = false;
            for (lf.supply[lf.off[k] + le]) |s| switch (s.kind) {
                .fresh, .shared => try f.drafts.items[di].supply[slot].append(f.gpa, s),
                .answer => {
                    // The answer of a function that `code` captured: this one's when it is this one.
                    if (f.capturedIs(code, s.a, root)) {
                        const acov = try m.loc.cover(lf.layouts[lf.arity], f.drafts.items[di].layouts[lf.arity]);
                        for (acov, 0..) |cv, ae| if (Loc.hits(cv, s.e)) try f.drafts.items[di].supply[slot].append(f.gpa, .{ .kind = .answer, .a = my_index, .e = @intCast(ae) });
                    } else try f.supplyLost(di, slot, inst, args);
                },
                .param => {
                    if (s.a >= code.own_params) {
                        // A value that `code` captured: handed in each run.
                        f.drafts.items[di].free[slot] = false;
                        if (s.a - code.own_params >= code.ncaps) {
                            try f.supplyLost(di, slot, inst, args);
                            continue;
                        }
                        const w: u32 = @intCast(f.atoms.items.len);
                        const dup = try f.argLeaves(f.lists.items[code.caps + s.a - code.own_params], lc.layouts[s.a], s.e, &.{}, &f.atoms);
                        try f.supplyAtoms(di, slot, w, inst, others, std.math.maxInt(usize), none, dup);
                        f.drafts.items[di].free[slot] = false;
                        continue;
                    }
                    // A parameter of `code`: what the callee hands `code` there.
                    const pcov = try m.loc.cover(fnc.layouts[s.a], lc.layouts[s.a]);
                    const fe = pcov[s.e];
                    if (fe >= Loc.all) {
                        try f.supplyLost(di, slot, inst, args);
                        continue;
                    }
                    if (!fnc.free[fnc.off[s.a] + fe]) f.drafts.items[di].free[slot] = false;
                    for (fnc.supply[fnc.off[s.a] + fe]) |ss| switch (ss.kind) {
                        .fresh, .shared => try f.drafts.items[di].supply[slot].append(f.gpa, ss),
                        .answer => {
                            // The answer of `code` itself comes back: what `code` answers there.
                            if (ss.a != j) {
                                try f.supplyLost(di, slot, inst, args);
                                continue;
                            }
                            const rcov = try m.loc.cover(fnc.layouts[fnc.arity], lc.layouts[lc.arity]);
                            for (rcov, 0..) |cv, re| {
                                if (!Loc.hits(cv, ss.e)) continue;
                                for (lc.res[re]) |ls| {
                                    if (ls.kind == .answer and f.capturedIs(code, ls.a, root)) {
                                        const acov = try m.loc.cover(lf.layouts[lf.arity], f.drafts.items[di].layouts[lf.arity]);
                                        for (acov, 0..) |cv2, ae| if (Loc.hits(cv2, ls.e)) try f.drafts.items[di].supply[slot].append(f.gpa, .{ .kind = .answer, .a = my_index, .e = @intCast(ae) });
                                    } else if (ls.kind == .fresh) {
                                        try f.drafts.items[di].supply[slot].append(f.gpa, Src.fresh);
                                    } else if (ls.kind == .param and ls.a == s.a and ls.e == s.e) {
                                        // `code` answers what it was handed here: no new source.
                                    } else try f.supplyLost(di, slot, inst, args);
                                }
                            }
                        },
                        .param => {
                            if (ss.a >= args.len) {
                                try f.supplyLost(di, slot, inst, args);
                                continue;
                            }
                            const w: u32 = @intCast(f.atoms.items.len);
                            const dup = try f.argLeaves(args[ss.a], c.layouts[ss.a], ss.e, &.{}, &f.atoms);
                            try f.supplyAtoms(di, slot, w, inst, others, ss.a, ss.e, dup);
                        },
                    };
                },
            };
        }
    }
}

/// Whether parameter `a` of the known function `code` is a capture that is the frame's own function at `root`.
fn capturedIs(f: *Frame, code: Code, a: u32, root: u32) bool {
    if (a < code.own_params or a - code.own_params >= code.ncaps) return false;
    return f.ownFnRoot(f.lists.items[code.caps + a - code.own_params]) == root;
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
            if (nfields == fields.len) {
                try f.leak(v, inst);
                continue;
            }
            fields[nfields] = .{ .name = m.symbolText(fd.name), .code = try f.codeOf(v) };
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
