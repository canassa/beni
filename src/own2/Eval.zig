//! L7: one walk of one code and its evaluations
//! (`docs/design/ownership-v2.md` §2.6, §2.10–§2.12).
//!
//! **The walk** goes over a code's instructions once, in their order (the
//! BIR numbers an operand before its consumer): a rule per tag (§2.6) gives
//! each instruction its value (§2.3.3), records the uses of locals at their
//! consumers (§2.7), the pending operands, the escapes, the demands of
//! constructions and `++` chains, and every call as a record whose result is
//! a root of its own. Nothing the walk does reads a callee's contract: a
//! call's leaves are expanded only by an evaluation. So a recursive group's
//! members are walked once each (§2.12), whatever their candidates.
//!
//! **An evaluation** reads the walk under the contracts its calls read now
//! (a group's candidates during the fixed point, the final ones at the end):
//! it maps each callee's labels, applies known codes to them (virtual calls),
//! makes each call's write demands, and reads the code's contract off
//! (§2.10 *Read-off*). `Resolve` judges the demands.
//!
//! Obligations kept here: O1 (unknown provenance: an unknown callee's
//! result is `⊤` and its arguments escape), O2's use half (a use is
//! recorded at its consumer, at its path, with its kind), O14 (a call is
//! instantiated once, its fresh objects one atom).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Regions = @import("Regions.zig");
const Liveness = @import("Liveness.zig");
const Prepass = @import("Prepass.zig");
const Bir = @import("../bir/Bir.zig");

pub const Error = Ids.ChargeError;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
const Inst = Bir.Inst;
const Step = Place.Step;
const Cond = Contract.Cond;
const none: u32 = Ids.none_int;

/// The high bit of a closure's `head`: a fixed contract, not a code.
pub const fixed_bit: u32 = 1 << 31;

/// What a call runs (`Context.callee`).
pub const Callee = union(enum) {
    /// The result and every argument cross: nothing to track.
    harmless,
    /// A constructor applied: `(ordinal, arity)`.
    ctor: [2]u32,
    /// A code of the module (`Groups`' numbering): its current contract.
    code: u32,
    /// A fixed contract: words, an import, a derived method, pessimistic.
    contract: Contract.Id,
    /// A function value: the head is evaluated.
    value,
};

/// The module's services a walk reads (`Groups` implements them).
pub const Context = struct {
    ctx: *anyopaque,
    placeOfInst: *const fn (ctx: *anyopaque, inst: u32) Error!PlaceId,
    placeOfLocal: *const fn (ctx: *anyopaque, local: u32) Error!PlaceId,
    fieldRank: *const fn (ctx: *anyopaque, s: Bir.SymbolIndex) u32,
    /// A constructor reference's `(ordinal, arity)`.
    ctorOf: *const fn (ctx: *anyopaque, ref: u32) ?[2]u32,
    /// A parameterless value's `(module, declaration)`.
    sharedOf: *const fn (ctx: *anyopaque, ref: u32) ?[2]u32,
    isListAppend: *const fn (ctx: *anyopaque, inst: u32) bool,
    callee: *const fn (ctx: *anyopaque, inst: u32, args: []const u32) Error!Callee,
    /// A function reference used as a value (`top`, `ext_value`, a
    /// constructor, a schema member): its code or fixed contract (with
    /// `fixed_bit`), or null when it is not a function.
    funcRef: *const fn (ctx: *anyopaque, inst: u32) Error!?u32,
    /// The code of a lambda or a local function's `let_def`.
    codeOf: *const fn (ctx: *anyopaque, inst: u32) ?u32,
    /// A code's captures (declaration-relative locals, sorted).
    capturesOf: *const fn (ctx: *anyopaque, code: u32) []const u32,
    /// A code's current contract, or null.
    contractOf: *const fn (ctx: *anyopaque, code: u32) ?Contract.Id,
    /// A code's places: its parameters' (own, then captures) and its result's.
    codeSig: *const fn (ctx: *anyopaque, code: u32) Error!Sig,
    /// The pessimistic contract of a call of `arity` arguments.
    pessimistic: *const fn (ctx: *anyopaque, arity: u32) Error!Contract.Id,
    /// A `try`'s shape: `(success ordinal, failure ordinal, failure
    /// arity)` of its scrutinee's type (`Ok`/`Err` or `Just`/`Nothing`),
    /// or null.
    tryShape: *const fn (ctx: *anyopaque, inst: u32) ?[3]u32,
};

pub const Sig = struct { params: []const PlaceId, own: u32, result: PlaceId };

/// What `Groups` hands a walk: the code and its frame of instructions.
pub const Code = struct {
    /// The declaration the code is in, and its index.
    decl: Bir.Decl,
    decl_index: u32,
    /// The lambda's or local function's instruction; `none` for the body.
    inst: u32,
    /// The code's parameter patterns.
    params: []const Inst.Index,
    /// Its parameters' places (the declaration's scheme for a body).
    param_places: []const PlaceId,
    /// Its captures' locals, after its own parameters.
    captures: []const u32,
    /// Its body instruction.
    body: u32,
    result_place: PlaceId,
};

/// A demand made by the walk or by an evaluation (§2.8): what `Resolve`
/// judges and `Message` says.
pub const Demand = struct {
    point: u32,
    kind: Facts.DemandKind,
    token: u32,
    /// The instruction whose value is the base, its text's root.
    base_inst: u32,
    /// The path below the base the write is at, for the text.
    write_path: PathId = .none,
    callee_inst: u32 = none,
    /// The written objects: a run of `Walk.leaf_runs`.
    targets: Ids.Range = .{},
    deep: bool = false,
    /// The other operands: a run of `Walk.value_runs`.
    operands: Ids.Range = .{},
    /// The operands pending at the point: a run of `Walk.pending_runs`.
    pending: Ids.Range = .{},
    /// What the callee's write relies on, instantiated on the arguments
    /// once the group's facts are delivered (`finishDemands`).
    relies: Cond = .{},
    /// The call whose callee writes (`none` for the walk's own demands),
    /// and the argument written.
    call: u32 = none,
    arg: u32 = none,
    /// A construction's base value: its storage, the targets, is read again
    /// by each evaluation (a prepend's re-cons reads the calls' contracts).
    base_value: u32 = none,
    /// The relied condition failed on the argument's own other paths.
    other_paths: bool = false,
    /// A callback's write (§2.11.3): accepted `callback-param`.
    callback: bool = false,
    /// A label's kept slot is written: refused `call`.
    kept: bool = false,
};

/// A local's binding.
pub const Binding = struct { value: u32 = none, point: u32 = none, token: u32 = none };

/// An escape (§2.4): a leaf at a point.
pub const Escape = struct { leaf: u32, point: u32, call: u32 = none };

/// A pending operand: its value, its instruction.
pub const Pending = struct { value: u32, inst: u32 };

/// A call's walk-time facts beside `Value.Call`.
pub const CallSite = struct {
    /// The pending operands at the call (a run of `pending_runs`).
    pending: Ids.Range,
    /// The call's arguments read through a footprint: the uses to filter.
    foot: Ids.Range,
};

/// A closure made in the frame (§2.11.4): its code, value and point.
pub const Closure = struct { code: u32, value: u32, point: u32, inst: u32 };

/// The residue of one walk: every table an evaluation reads.
pub const Walk = struct {
    f: Value.Frame,
    code: Code,
    bir: *const Bir,
    bindings: []Binding,
    uses: std.ArrayList(Facts.Use) = .empty,
    /// Per use of kind `call`: its call and argument (`use_node`).
    foots: std.ArrayList([2]u32) = .empty,
    /// The local each `.local` read was of, per use (for texts).
    demands: std.ArrayList(Demand) = .empty,
    escapes: std.ArrayList(Escape) = .empty,
    sites: std.ArrayList(CallSite) = .empty,
    closures: std.ArrayList(Closure) = .empty,
    pending_runs: std.ArrayList(Pending) = .empty,
    value_runs: std.ArrayList(u32) = .empty,
    leaf_runs: std.ArrayList(u32) = .empty,
    result: u32 = none,
    /// Per root: the local whose parameter pattern it is, for texts.
    regions: *const Regions.Tree,
    index: Liveness.Index = .{},
    /// Interned across evaluations, so a label met again is one record:
    /// `(call, callee label)` → its virtual call; a derived label's identity
    /// `(j, slot, origin)` → its `cbs` record; `(call, label, k)` → a supply.
    virt: Ids.FixedDict(2) = .{},
    derived: Ids.FixedDict(5) = .{},
    supply_of: Ids.FixedDict(3) = .{},
    /// The calls and labels the walk made, before any evaluation's.
    walk_calls: u32 = 0,

    pub fn deinit(w: *Walk) void {
        const gpa = w.f.gpa;
        w.f.deinit();
        gpa.free(w.bindings);
        w.uses.deinit(gpa);
        w.foots.deinit(gpa);
        w.demands.deinit(gpa);
        w.escapes.deinit(gpa);
        w.sites.deinit(gpa);
        w.closures.deinit(gpa);
        w.pending_runs.deinit(gpa);
        w.value_runs.deinit(gpa);
        w.leaf_runs.deinit(gpa);
        w.index.deinit(gpa);
        w.virt.deinit(gpa);
        w.derived.deinit(gpa);
        w.supply_of.deinit(gpa);
    }

    pub fn leavesOfRun(w: *const Walk, r: Ids.Range) []const u32 {
        return w.leaf_runs.items[r.start..][0..r.len];
    }
    pub fn valuesOfRun(w: *const Walk, r: Ids.Range) []const u32 {
        return w.value_runs.items[r.start..][0..r.len];
    }
    pub fn pendingOfRun(w: *const Walk, r: Ids.Range) []const Pending {
        return w.pending_runs.items[r.start..][0..r.len];
    }
};

// ===========================================================================
// The walk
// ===========================================================================

/// What an instruction evaluated to: its value, and the local and path it
/// reads when it is a local or a field chain over one.
const Res = struct { v: u32 = none, local: u32 = none, path: PathId = .none };

const Walker = struct {
    w: *Walk,
    ctx: Context,
    bir: *const Bir,
    prepass: *const Facts.Prepass,
    gpa: Allocator,
    /// Per instruction of the declaration: its result in this walk.
    res: []Res,
    consumer: []u32,
    /// A `let_pattern`'s value instruction → its pattern.
    binds: []u32,
    /// A case arm's pattern root → its scrutinee.
    matches: []u32,
    /// Spread chains by root, and the instructions a chain absorbed.
    chain: []u32,
    absorbed: []bool,
    /// The operand stack (§2.4): instructions evaluated, consumer not yet run.
    stack: std.ArrayList(u32) = .empty,
    atom: *u32,
    scratch: std.ArrayList(Inst.Index) = .empty,
    early: std.ArrayList(Early) = .empty,
    module: u32 = 0,

    fn f(k: *Walker) *Value.Frame {
        return &k.w.f;
    }
    fn tag(k: *const Walker, i: u32) Inst.Tag {
        return k.bir.instTag(@fromBackingInt(i));
    }
    fn data(k: *const Walker, i: u32) Inst.Data {
        return k.bir.instData(@fromBackingInt(i));
    }
    fn rel(k: *const Walker, i: u32) u32 {
        return i - k.w.code.decl.inst_start.int();
    }
    fn token(k: *const Walker, i: u32) u32 {
        return k.bir.insts.items(.main_token)[i];
    }
    fn placeOf(k: *Walker, i: u32) Error!PlaceId {
        return k.ctx.placeOfInst(k.ctx.ctx, i);
    }
    fn args(k: *const Walker, c: u32) []const Inst.Index {
        return k.bir.extraSlice(k.bir.subRange(@fromBackingInt(k.data(c).rhs)), Inst.Index);
    }
    fn charge(k: *Walker, cat: Ids.Category, n: u32) Error!void {
        try k.w.f.account.reserve(cat, n);
    }

    /// Whether instruction `i` belongs to this code's frame.
    fn mine(k: *const Walker, i: u32) bool {
        const fr = k.prepass.enclosing_frame[i];
        return fr == k.w.code.inst;
    }

    fn valueOf(k: *Walker, i: u32) Error!u32 {
        const r = k.res[k.rel(i)];
        if (r.v == none) return k.f().scalar();
        return r.v;
    }

    // ---- uses ---------------------------------------------------------------

    fn use(k: *Walker, operand: u32, point: u32, kind: Facts.UseKind, foot: [2]u32) Error!void {
        const r = k.res[k.rel(operand)];
        if (r.local == none or r.path == .none) return;
        try k.charge(.use, 1);
        var node: Ids.NodeId = .none;
        if (kind == .call) {
            node = .from(@intCast(k.w.foots.items.len));
            try k.w.foots.append(k.gpa, foot);
        }
        k.atom.* += 1;
        try k.w.uses.append(k.gpa, .{ .local = r.local, .path = r.path, .point = point, .kind = kind, .region = k.w.regions.regionOf(point), .use_node = node, .atom = k.atom.* });
    }

    fn consume(k: *Walker, operand: u32, point: u32) Error!void {
        try k.use(operand, point, .whole, .{ none, none });
        k.pop(operand);
    }

    fn pop(k: *Walker, operand: u32) void {
        if (k.stack.items.len != 0 and k.stack.items[k.stack.items.len - 1] == operand) {
            _ = k.stack.pop();
            return;
        }
        for (k.stack.items, 0..) |x, i| if (x == operand) {
            _ = k.stack.orderedRemove(i);
            return;
        };
    }

    /// The pending operands at `point`, as a run (§2.4): an earlier arm's
    /// value waits for its `case`, but never runs with this point.
    fn pendingRun(k: *Walker, point: u32) Error!Ids.Range {
        const start: u32 = @intCast(k.w.pending_runs.items.len);
        for (k.stack.items) |i| {
            const v = k.res[k.rel(i)].v;
            if (v == none) continue;
            if (!k.w.regions.compatible(i, point)) continue;
            try k.w.pending_runs.append(k.gpa, .{ .value = v, .inst = i });
        }
        return .{ .start = start, .len = @intCast(k.w.pending_runs.items.len - start) };
    }

    // ---- binding ------------------------------------------------------------

    fn bindLocal(k: *Walker, local: u32, v: u32, point: u32, tok: u32) Error!void {
        if (local >= k.w.bindings.len) return;
        try k.charge(.shape, 1);
        k.w.bindings[local] = .{ .value = v, .point = point, .token = tok };
    }

    fn placeOfLocal(k: *Walker, local: u32) Error!PlaceId {
        return k.ctx.placeOfLocal(k.ctx.ctx, local);
    }

    /// Bind pattern `pat` to value `v` at `point`.
    fn bind(k: *Walker, pat0: u32, v0: u32, point: u32) Error!void {
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(k.gpa);
        try stack.append(k.gpa, .{ pat0, v0 });
        while (stack.pop()) |it| {
            const pat = it[0];
            const v = it[1];
            try k.charge(.inspection, 1);
            const d = k.data(pat);
            const tok = k.token(pat);
            switch (k.tag(pat)) {
                .pat_var => try k.bindLocal(d.lhs, v, point, tok),
                .pat_as => {
                    try k.bindLocal(d.rhs, v, point, tok);
                    try stack.append(k.gpa, .{ d.lhs, v });
                },
                .pat_ctor => {
                    const c = k.ctx.ctorOf(k.ctx.ctx, d.lhs) orelse continue;
                    for (k.args(pat), 0..) |a, n| {
                        const st = try k.f().places.ctorStep(k.gpa, k.f().account, c[0], @intCast(n));
                        try stack.append(k.gpa, .{ a.int(), try k.project(v, .plain, st.word(), 0) });
                    }
                },
                .pat_tuple => for (k.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |a, n| {
                    const st = try Step.index(k.f().account, @intCast(n));
                    try stack.append(k.gpa, .{ a.int(), try k.project(v, .plain, st.word(), 0) });
                },
                .pat_record => for (k.bir.extraSlice(Bir.inlineRange(d), u32)) |local| {
                    const sym = k.bir.locals[k.w.code.decl.locals_start + local].name;
                    const st = try Step.field(k.f().account, k.ctx.fieldRank(k.ctx.ctx, sym));
                    try k.bindLocal(local, try k.project(v, .plain, st.word(), 0), point, tok);
                },
                .pat_list => {
                    const items = k.bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                    var spread: ?usize = null;
                    for (items, 0..) |a, n| if (k.tag(a.int()) == .pat_spread) {
                        spread = n;
                    };
                    for (items, 0..) |a, n| {
                        const kind: Value.PKind, const x: u32, const y: u32 = if (spread) |sp|
                            (if (n < sp) .{ .front, @as(u32, @intCast(n)), 0 } else if (n == sp) .{ .slice, @as(u32, @intCast(sp)), @as(u32, @intCast(items.len - 1 - sp)) } else .{ .back, @as(u32, @intCast(items.len - 1 - n)), 0 })
                        else
                            .{ .front, @as(u32, @intCast(n)), 0 };
                        const kv = try k.project(v, kind, x, y);
                        const inner = if (k.tag(a.int()) == .pat_spread) k.data(a.int()).lhs else a.int();
                        try stack.append(k.gpa, .{ inner, kv });
                    }
                },
                .pat_spread => try stack.append(k.gpa, .{ d.lhs, v }),
                else => {},
            }
        }
    }

    // ---- projection of a value by one step -------------------------------------

    /// Value `v` projected by a step (§2.3.3): a literal's part, a position.
    fn project(k: *Walker, v: u32, kind: Value.PKind, a: u32, b: u32) Error!u32 {
        try k.charge(.inspection, 1);
        const fr = k.f();
        const x = fr.val(v);
        switch (x.kind) {
            .scalar, .bot, .top, .shared => return v,
            .ref => {
                if (x.family != Slots.empty) {
                    const sw: Step = if (kind == .plain) Step.fromWord(a) else Step.elem;
                    var objs: std.ArrayList(u32) = .empty;
                    defer objs.deinit(k.gpa);
                    for (fr.slots.items(x.family)) |t| {
                        if (kind == .slice) {
                            try objs.append(k.gpa, t);
                            continue;
                        }
                        const at = (try fr.places.extend(k.gpa, fr.gc(), .from(t), sw)) orelse continue;
                        try objs.append(k.gpa, at.int());
                    }
                    if (objs.items.len == 0) return fr.scalar();
                    // A family's slots stay paths (not only object slots): it
                    // is projected further.
                    const set = try fr.slots.sorted(k.gpa, fr.account, objs.items);
                    return fr.mk(.{ .kind = .ref, .root = x.root, .pos = x.pos, .family = set });
                }
                const p = (try fr.child(x.pos, kind, a, b)) orelse return fr.scalar();
                return fr.mk(.{ .kind = .ref, .root = x.root, .pos = p, .place = fr.places.pathPlace(fr.pos.items[p].slot) });
            },
            .built => {
                const ks = fr.kidsOf(x);
                switch (x.form) {
                    .tuple, .ctor => {
                        if (kind != .plain) return fr.scalar();
                        const st = Step.fromWord(a);
                        switch (st.kind) {
                            .index => if (x.form == .tuple and st.payload < ks.len) return ks[st.payload],
                            .ctor_arg => {
                                const ca = fr.places.ctorArgOf(st);
                                if (x.form == .ctor and ca[0] == x.head and ca[1] < ks.len) return ks[ca[1]];
                            },
                            else => {},
                        }
                        return fr.scalar();
                    },
                    .record => {
                        if (kind != .plain) return fr.scalar();
                        const st = Step.fromWord(a);
                        for (fr.wordsOf(x.extra), 0..) |r, n| if (st.kind == .field and r == st.payload) return ks[n];
                        return fr.scalar();
                    },
                    .list => switch (kind) {
                        .front, .back => {
                            // A spread kid has a length not known: the index
                            // may land on it or on any kid after it.
                            const flags = fr.wordsOf(x.extra);
                            if (flags.len == 0) {
                                if (a >= ks.len) return fr.bot();
                                return if (kind == .front) ks[a] else ks[ks.len - 1 - a];
                            }
                            var cands: std.ArrayList(u32) = .empty;
                            defer cands.deinit(k.gpa);
                            var exact = true;
                            var idx: u32 = 0;
                            for (0..ks.len) |n0| {
                                const n = if (kind == .front) n0 else ks.len - 1 - n0;
                                if (flags[n] != 0) {
                                    exact = false;
                                    try cands.appendSlice(k.gpa, &.{ @intCast(n), ks[n] });
                                } else if (!exact) {
                                    try cands.appendSlice(k.gpa, &.{ @intCast(n), ks[n] });
                                } else {
                                    if (idx == a) return ks[n];
                                    idx += 1;
                                }
                            }
                            if (cands.items.len == 0) return fr.bot();
                            if (cands.items.len == 2) return cands.items[1];
                            return fr.mk(.{ .kind = .alt, .head = if (x.site != none) 0x8000_0000 | x.site else 0xC000_0000 | (x.head & 0x3fff_ffff), .kids = try fr.mkKids(cands.items) });
                        },
                        .slice => {
                            // With spreads the view may hold any kid.
                            if (fr.wordsOf(x.extra).len != 0) return v;
                            const lo = @min(a, ks.len);
                            const hi = ks.len - @min(b, ks.len - lo);
                            // A view: the same storage, fewer elements.
                            return fr.mk(.{ .kind = .built, .form = .list, .site = x.site, .place = x.place, .kids = try fr.mkKids(ks[lo..hi]) });
                        },
                        .plain => {
                            if (Step.fromWord(a).kind != .elem) return fr.scalar();
                            if (ks.len == 0) return fr.bot();
                            if (ks.len == 1) return ks[0];
                            const arms = try k.gpa.alloc(u32, ks.len * 2);
                            defer k.gpa.free(arms);
                            for (ks, 0..) |kv, n| {
                                arms[2 * n] = @intCast(n);
                                arms[2 * n + 1] = kv;
                            }
                            // One element at a time: a choice keyed by the literal.
                            return fr.mk(.{ .kind = .alt, .head = 0x8000_0000 | x.site, .kids = try fr.mkKids(arms) });
                        },
                    },
                    .closure, .opaque_ => return v,
                }
            },
            .alt => {
                const ks = fr.kidsOf(x);
                var arms: std.ArrayList(u32) = .empty;
                defer arms.deinit(k.gpa);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) {
                    const p = try k.project(ks[i + 1], kind, a, b);
                    if (fr.val(p).kind == .bot) continue;
                    try arms.appendSlice(k.gpa, &.{ ks[i], p });
                }
                if (arms.items.len == 0) return fr.bot();
                return fr.mk(.{ .kind = .alt, .head = x.head, .kids = try fr.mkKids(arms.items) });
            },
        }
    }

    // ---- the rules ----------------------------------------------------------

    fn literalPlace(k: *Walker, i: u32) Error!PlaceId {
        return k.placeOf(i);
    }

    fn built(k: *Walker, i: u32, form: Value.Form, head: u32, site: u32, kids: []const u32, extra: []const u32) Error!u32 {
        return k.f().mk(.{ .kind = .built, .form = form, .head = head, .site = site, .extra = extra, .place = try k.literalPlace(i), .kids = try k.f().mkKids(kids) });
    }

    /// The rule of instruction `i` (§2.6).
    fn eval(k: *Walker, i: u32) Error!Res {
        const d = k.data(i);
        const fr = k.f();
        switch (k.tag(i)) {
            .local => {
                const b = if (d.lhs < k.w.bindings.len) k.w.bindings[d.lhs] else Binding{};
                if (b.value == none) return .{ .v = try fr.top() };
                const at = try k.placeOfLocal(d.lhs);
                return .{ .v = b.value, .local = d.lhs, .path = try fr.places.rootPath(k.gpa, at) };
            },
            .field_access, .tuple_index => {
                const target = k.res[k.rel(d.lhs)];
                const st = if (k.tag(i) == .field_access) try Step.field(fr.account, k.ctx.fieldRank(k.ctx.ctx, @fromBackingInt(d.rhs))) else try Step.index(fr.account, d.rhs);
                const v = try k.project(try k.valueOf(d.lhs), .plain, st.word(), 0);
                k.pop(d.lhs);
                if (target.local != none) {
                    if (try fr.places.extend(k.gpa, fr.gc(), target.path, st)) |p| return .{ .v = v, .local = target.local, .path = p };
                    try k.use(d.lhs, i, .whole, .{ none, none });
                }
                return .{ .v = v };
            },
            .top, .ext_value, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor => {
                if (k.isCallee(i)) return .{};
                if (k.ctx.sharedOf(k.ctx.ctx, i)) |md| {
                    if (Slots.holdsAny(fr.places, try fr.places.rootPath(k.gpa, try k.placeOf(i)))) return .{ .v = try fr.mk(.{ .kind = .shared, .head = md[0], .site = md[1] }) };
                    return .{ .v = try fr.scalar() };
                }
                if (try k.ctx.funcRef(k.ctx.ctx, i)) |code| return .{ .v = try k.closureOf(i, code, &.{}) };
                return .{ .v = try fr.top() };
            },
            .ctor, .ext_ctor => {
                if (k.isCallee(i)) return .{};
                const c = k.ctx.ctorOf(k.ctx.ctx, i) orelse return .{ .v = try fr.top() };
                if (c[1] == 0) return .{ .v = try fr.mk(.{ .kind = .built, .form = .ctor, .head = c[0], .place = try k.placeOf(i) }) };
                if (try k.ctx.funcRef(k.ctx.ctx, i)) |code| return .{ .v = try k.closureOf(i, code, &.{}) };
                return .{ .v = try fr.top() };
            },
            .int, .float, .char, .string, .chunk, .unit => return .{ .v = try fr.scalar() },
            .interp => {
                for (k.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |p| try k.consume(p.int(), i);
                return .{ .v = try fr.scalar() };
            },
            .@"error" => return .{ .v = try fr.top() },
            .list => {
                const items = k.bir.extraSlice(Bir.inlineRange(d), Inst.Index);
                var ks: std.ArrayList(u32) = .empty;
                defer ks.deinit(k.gpa);
                for (items) |e| {
                    try ks.append(k.gpa, try k.valueOf(e.int()));
                    try k.consume(e.int(), i);
                }
                return .{ .v = try k.built(i, .list, 0, i, ks.items, &.{}) };
            },
            .tuple => {
                var ks: std.ArrayList(u32) = .empty;
                defer ks.deinit(k.gpa);
                for (k.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |e| {
                    try ks.append(k.gpa, try k.valueOf(e.int()));
                    try k.consume(e.int(), i);
                }
                return .{ .v = try k.built(i, .tuple, 0, none, ks.items, &.{}) };
            },
            .record => {
                const fields = k.bir.extraSlice(Bir.inlineRange(d), Bir.Field);
                return .{ .v = try k.record(i, fields, null) };
            },
            .record_update => {
                // A record built from the base's fields and the new values
                // (§2.11.5): no storage of the base is written.
                const fields = k.bir.extraSlice(k.bir.subRange(@fromBackingInt(d.rhs)), Bir.Field);
                return .{ .v = try k.record(i, fields, d.lhs) };
            },
            .call => {
                if (k.ctx.isListAppend(k.ctx.ctx, i) and k.args(i).len == 2) return .{ .v = try k.appendChain(i) };
                var all: std.ArrayList(u32) = .empty;
                defer all.deinit(k.gpa);
                for (k.args(i)) |a| try all.append(k.gpa, a.int());
                return .{ .v = try k.call(i, d.lhs, all.items) };
            },
            .method_call => {
                const m = k.bir.extraData(@fromBackingInt(d.rhs), Bir.MethodCall);
                var all: std.ArrayList(u32) = .empty;
                defer all.deinit(k.gpa);
                try all.append(k.gpa, d.lhs);
                for (k.bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Inst.Index)) |a| try all.append(k.gpa, a.int());
                return .{ .v = try k.call(i, none, all.items) };
            },
            .type_dispatch => {
                const t = k.bir.extraData(@fromBackingInt(d.rhs), Bir.TypeDispatch);
                for (k.bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Inst.Index)) |a| {
                    try k.escapeValue(try k.valueOf(a.int()), i);
                    try k.consume(a.int(), i);
                }
                return .{ .v = try fr.top() };
            },
            .lambda => {
                const code = k.ctx.codeOf(k.ctx.ctx, i) orelse return .{ .v = try fr.top() };
                return .{ .v = try k.closureOf(i, code, k.ctx.capturesOf(k.ctx.ctx, code)) };
            },
            .let => return k.res[k.rel(d.rhs)],
            .let_def => {
                const def = k.bir.extraData(@fromBackingInt(d.lhs), Bir.LetDef);
                if (def.params_end != def.params_start) {
                    const code = k.ctx.codeOf(k.ctx.ctx, i) orelse return .{};
                    const v = try k.closureOf(i, code, k.ctx.capturesOf(k.ctx.ctx, code));
                    try k.bindLocal(def.local, v, i, k.token(i));
                }
                return .{};
            },
            .let_pattern => return .{},
            .let_stmt => {
                try k.consume(d.rhs, i);
                return .{};
            },
            .branch => {
                try k.consume(d.rhs, i);
                return .{ .v = try k.valueOf(d.rhs) };
            },
            .case => {
                const branches = k.bir.extraSlice(k.bir.subRange(@fromBackingInt(d.rhs)), Inst.Index);
                var arms: std.ArrayList(u32) = .empty;
                defer arms.deinit(k.gpa);
                for (branches, 0..) |b, n| {
                    const v = try k.valueOf(b.int());
                    k.pop(b.int());
                    if (fr.val(v).kind == .bot) continue;
                    try arms.appendSlice(k.gpa, &.{ @intCast(n), v });
                }
                if (arms.items.len == 0) return .{ .v = try fr.bot() };
                if (arms.items.len == 2) return .{ .v = arms.items[1] };
                return .{ .v = try fr.mk(.{ .kind = .alt, .head = i, .kids = try fr.mkKids(arms.items) }) };
            },
            .@"try" => {
                // The success payload; the failure's is a returned alternative
                // of the definition it returns from (§2.11.5).
                const scrut = try k.valueOf(d.lhs);
                k.pop(d.lhs);
                try k.use(d.lhs, i, .whole, .{ none, none });
                const shape = k.ctx.tryShape(k.ctx.ctx, i) orelse return .{ .v = try fr.top() };
                var payload: u32 = none;
                if (shape[2] != 0) {
                    const st = try fr.places.ctorStep(k.gpa, fr.account, shape[1], 0);
                    payload = try k.project(scrut, .plain, st.word(), 0);
                }
                try k.early.append(k.gpa, .{ .v = payload, .ord = shape[1], .arg = 0, .target = d.rhs, .inst = i });
                const st = try fr.places.ctorStep(k.gpa, fr.account, shape[0], 0);
                return .{ .v = try k.project(scrut, .plain, st.word(), 0) };
            },
            .markup => {
                // An opaque value holding every embedded value (§2.11.5).
                k.scratch.clearRetainingCapacity();
                try k.bir.markupValues(k.gpa, @fromBackingInt(d.lhs), &k.scratch);
                var ks: std.ArrayList(u32) = .empty;
                defer ks.deinit(k.gpa);
                for (k.scratch.items) |e| {
                    if (!k.mine(e.int())) continue;
                    try ks.append(k.gpa, try k.valueOf(e.int()));
                    try k.consume(e.int(), i);
                }
                return .{ .v = try k.built(i, .opaque_, 0, i, ks.items, &.{}) };
            },
            else => return .{},
        }
    }

    fn isCallee(k: *const Walker, i: u32) bool {
        const c = k.consumer[k.rel(i)];
        return c != none and (k.tag(c) == .call or k.tag(c) == .pat_ctor) and k.data(c).lhs == i;
    }

    /// A record literal, or an update's copy (`base` its base instruction).
    fn record(k: *Walker, i: u32, fields: []const Bir.Field, base: ?u32) Error!u32 {
        const fr = k.f();
        var ranks: std.ArrayList(u32) = .empty;
        defer ranks.deinit(k.gpa);
        var ks: std.ArrayList(u32) = .empty;
        defer ks.deinit(k.gpa);
        for (fields) |fl| {
            try ranks.append(k.gpa, k.ctx.fieldRank(k.ctx.ctx, fl.name));
            try ks.append(k.gpa, try k.valueOf(fl.value.int()));
            try k.consume(fl.value.int(), i);
        }
        if (base) |b| {
            // The untouched fields: the base's, each a `field` use of it.
            const bv = try k.valueOf(b);
            const at = try k.placeOf(i);
            const pr = fr.places.steps(at);
            for (pr.steps) |st| {
                if (st.kind != .field) continue;
                if (std.mem.indexOfScalar(u32, ranks.items, st.payload) != null) continue;
                try ranks.append(k.gpa, st.payload);
                try ks.append(k.gpa, try k.project(bv, .plain, st.word(), 0));
                const r = k.res[k.rel(b)];
                if (r.local != none) if (try fr.places.extend(k.gpa, fr.gc(), r.path, st)) |p| {
                    k.atom.* += 1;
                    try k.w.uses.append(k.gpa, .{ .local = r.local, .path = p, .point = i, .kind = .field, .region = k.w.regions.regionOf(i), .use_node = .none, .atom = k.atom.* });
                };
            }
            k.pop(b);
        }
        // Fields in rank order, as the place's steps.
        const n = ranks.items.len;
        const order = try k.gpa.alloc(u32, n);
        defer k.gpa.free(order);
        for (order, 0..) |*o, x| o.* = @intCast(x);
        std.mem.sort(u32, order, ranks.items, struct {
            fn lt(r: []u32, x: u32, y: u32) bool {
                return r[x] < r[y];
            }
        }.lt);
        var sr: std.ArrayList(u32) = .empty;
        defer sr.deinit(k.gpa);
        var sk: std.ArrayList(u32) = .empty;
        defer sk.deinit(k.gpa);
        for (order) |o| {
            try sr.append(k.gpa, ranks.items[o]);
            try sk.append(k.gpa, ks.items[o]);
        }
        return k.built(i, .record, 0, i, sk.items, try fr.mkWords(sr.items));
    }

    /// A closure value of `code` (or a fixed contract) holding the values
    /// of `captures` (§2.11.4).
    fn closureOf(k: *Walker, i: u32, code: u32, captures: []const u32) Error!u32 {
        var ks: std.ArrayList(u32) = .empty;
        defer ks.deinit(k.gpa);
        for (captures) |l| {
            const b = if (l < k.w.bindings.len) k.w.bindings[l] else Binding{};
            try ks.append(k.gpa, if (b.value == none) try k.f().top() else b.value);
            // A capture is read at the closure's creation.
            if (b.value != none) {
                const at = try k.placeOfLocal(l);
                k.atom.* += 1;
                try k.w.uses.append(k.gpa, .{ .local = l, .path = try k.f().places.rootPath(k.gpa, at), .point = i, .kind = .whole, .region = k.w.regions.regionOf(i), .use_node = .none, .atom = k.atom.* });
            }
        }
        const v = try k.built(i, .closure, code, if (code & fixed_bit == 0) i else none, ks.items, &.{});
        if (code & fixed_bit == 0) try k.w.closures.append(k.gpa, .{ .code = code, .value = v, .point = i, .inst = i });
        return v;
    }

    fn escapeValue(k: *Walker, v: u32, point: u32) Error!void {
        var ev: Relation.Eval = .{ .f = k.f(), .contracts = undefined, .arena = k.f().arena };
        defer ev.deinit();
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(k.gpa);
        try ev.leavesOf(v, 0, &ls);
        for (ls.items) |l| try k.w.escapes.append(k.gpa, .{ .leaf = l, .point = point });
    }

    // ---- calls --------------------------------------------------------------

    /// A call at `i` of the callee instruction `head` (`none` for a method
    /// call) with argument instructions `arg_insts`.
    fn call(k: *Walker, i: u32, head: u32, arg_insts: []const u32) Error!u32 {
        const fr = k.f();
        var vals: std.ArrayList(u32) = .empty;
        defer vals.deinit(k.gpa);
        for (arg_insts) |a| try vals.append(k.gpa, try k.valueOf(a));
        const callee = try k.ctx.callee(k.ctx.ctx, i, arg_insts);
        switch (callee) {
            .harmless => {
                for (arg_insts) |a| try k.consume(a, i);
                return fr.scalar();
            },
            .ctor => |c| {
                for (arg_insts) |a| try k.consume(a, i);
                return k.built(i, .ctor, c[0], none, vals.items, &.{});
            },
            .code => |c| {
                var caps: std.ArrayList(u32) = .empty;
                defer caps.deinit(k.gpa);
                for (k.ctx.capturesOf(k.ctx.ctx, c)) |l| {
                    const b = if (l < k.w.bindings.len) k.w.bindings[l] else Binding{};
                    try caps.append(k.gpa, if (b.value == none) try fr.top() else b.value);
                }
                return k.codeCall(i, c, null, arg_insts, vals.items, caps.items);
            },
            .contract => |c| return k.codeCall(i, none, c, arg_insts, vals.items, &.{}),
            .value => {
                const fv = if (head != none) try k.valueOf(head) else try fr.top();
                if (head != none) {
                    try k.use(head, i, .whole, .{ none, none });
                    k.pop(head);
                }
                return k.valueCall(i, fv, arg_insts, vals.items, 0);
            },
        }
    }

    /// A call of function value `fv` (§2.11.3–4).
    fn valueCall(k: *Walker, i: u32, fv: u32, arg_insts: []const u32, vals: []const u32, depth: u32) Error!u32 {
        const fr = k.f();
        const x = fr.val(fv);
        switch (x.kind) {
            .built => if (x.form == .closure) {
                const r = if (x.head & fixed_bit != 0) try k.codeCall(i, none, x.head & ~fixed_bit, arg_insts, vals, fr.kidsOf(x)) else try k.codeCall(i, x.head, null, arg_insts, vals, fr.kidsOf(x));
                fr.calls.items[fr.calls.items.len - 1].callee_val = fv;
                return r;
            },
            .alt => if (depth < 8) {
                const ks = fr.kidsOf(x);
                var arms: std.ArrayList(u32) = .empty;
                defer arms.deinit(k.gpa);
                var n: usize = 0;
                while (n < ks.len) : (n += 2) try arms.appendSlice(k.gpa, &.{ ks[n], try k.valueCall(i, ks[n + 1], arg_insts, vals, depth + 1) });
                if (depth == 0) for (arg_insts) |a| k.pop(a);
                return fr.mk(.{ .kind = .alt, .head = x.head, .kids = try fr.mkKids(arms.items) });
            },
            .ref => if (fr.roots.items[x.root].kind == .param and x.family == Slots.empty) {
                // A callback call (§2.11.3): a label of the frame.
                const r = fr.roots.items[x.root];
                const slot = try fr.slots.relOf(k.gpa, fr.account, fr.places, fr.pos.items[x.pos].slot);
                const at = try k.placeOf(i);
                const cbi: u32 = @intCast(fr.cbs.items.len);
                const root = try fr.addRoot(.cb, cbi, at);
                for (arg_insts) |a| try k.consume(a, i);
                try fr.cbs.append(k.gpa, .{ .j = r.a, .slot = slot, .origin = .{ k.module, k.w.code.decl_index, i - k.w.code.decl.inst_start.int() }, .root = root, .inst = i, .point = i, .args = try fr.mkKids(vals), .calls = 1, .pending = try k.pendingRun(i) });
                return fr.refRoot(root);
            },
            else => {},
        }
        // Unknown code: its answer is unknown and what it is handed escapes.
        for (vals) |v| try k.escapeValue(v, i);
        if (depth == 0) for (arg_insts) |a| try k.consume(a, i);
        return fr.top();
    }

    /// A call of a code or a fixed contract; `captures` follow the arguments.
    fn codeCall(k: *Walker, i: u32, code: u32, fixed: ?Contract.Id, arg_insts: []const u32, vals: []const u32, captures: []const u32) Error!u32 {
        const fr = k.f();
        const ci: u32 = @intCast(fr.calls.items.len);
        // Arguments read through the callee's footprint (§2.7).
        for (arg_insts, 0..) |a, n| {
            try k.use(a, i, .call, .{ ci, @intCast(n) });
            k.pop(a);
        }
        var all: std.ArrayList(u32) = .empty;
        defer all.deinit(k.gpa);
        try all.appendSlice(k.gpa, vals);
        try all.appendSlice(k.gpa, captures);
        var insts: std.ArrayList(u32) = .empty;
        defer insts.deinit(k.gpa);
        try insts.appendSlice(k.gpa, arg_insts);
        for (captures) |_| try insts.append(k.gpa, none);
        const at = try k.placeOf(i);
        const root = try fr.addRoot(.call, ci, at);
        const head: u32 = if (k.tag(i) == .call) k.data(i).lhs else i;
        try fr.calls.append(k.gpa, .{ .inst = i, .head = head, .point = i, .args = try fr.mkKids(all.items), .arg_insts = try fr.mkWords(insts.items), .root = root, .code = code, .contract = if (fixed) |c| c else none });
        try k.w.sites.append(k.gpa, .{ .pending = try k.pendingRun(i), .foot = .{} });
        if (!Slots.holdsAny(fr.places, fr.roots.items[root].path)) return fr.scalar();
        return fr.refRoot(root);
    }

    // ---- constructions --------------------------------------------------------

    /// A `++` chain: one `append` demand on the leftmost base (R-2.2).
    fn appendChain(k: *Walker, i: u32) Error!u32 {
        var items: std.ArrayList(u32) = .empty;
        defer items.deinit(k.gpa);
        var at = i;
        while (true) {
            const a = k.args(at);
            try items.append(k.gpa, a[0].int());
            const rhs = a[1].int();
            if (k.tag(rhs) == .call and k.ctx.isListAppend(k.ctx.ctx, rhs) and k.args(rhs).len == 2 and k.absorbed[k.rel(rhs)]) {
                at = rhs;
                continue;
            }
            try items.append(k.gpa, rhs);
            break;
        }
        return k.construction(i, items.items, .append, items.items[0], null);
    }

    /// A spread chain (§2.13.2): a prepend, or a construction over its base.
    fn spreadChain(k: *Walker, i: u32, s: Bir.Spread) Error!u32 {
        const its = k.bir.spreadItems(s);
        var items: std.ArrayList(u32) = .empty;
        defer items.deinit(k.gpa);
        var first_spread: ?usize = null;
        const spread = try k.f().arena.alloc(bool, its.len);
        for (its, 0..) |it, n| {
            try items.append(k.gpa, it[0]);
            spread[n] = it[1] != 0;
            if (it[1] != 0 and first_spread == null) first_spread = n;
        }
        const sp = first_spread orelse return k.literalOf(i, items.items);
        if (sp == its.len - 1 and its.len >= 1) {
            // `[ x₁…xₖ, …xs ]`: a prepend — fresh storage, the fronts and xs's elements.
            return k.prepend(i, items.items[0..sp], items.items[sp]);
        }
        return k.construction(i, items.items, .construction, items.items[sp], spread);
    }

    fn literalOf(k: *Walker, i: u32, items: []const u32) Error!u32 {
        var ks: std.ArrayList(u32) = .empty;
        defer ks.deinit(k.gpa);
        for (items) |e| {
            try ks.append(k.gpa, try k.valueOf(e));
            try k.consume(e, i);
        }
        return k.built(i, .list, 0, i, ks.items, &.{});
    }

    /// `[ x₁…xₖ, …xs ]`: a new list whose elements are the fronts and xs's.
    fn prepend(k: *Walker, i: u32, fronts: []const u32, rest: u32) Error!u32 {
        var ks: std.ArrayList(u32) = .empty;
        defer ks.deinit(k.gpa);
        for (fronts) |e| {
            try ks.append(k.gpa, try k.valueOf(e));
            try k.consume(e, i);
        }
        const xs = try k.valueOf(rest);
        try k.consume(rest, i);
        try ks.append(k.gpa, try k.project(xs, .plain, Step.elem.word(), 0));
        // The elements of `xs` are the last kid as a family, not a literal element.
        const flags = try k.f().arena.alloc(u32, ks.items.len);
        @memset(flags, 0);
        flags[flags.len - 1] = 1;
        // Its storage is fresh, or `xs`'s base re-consed (§2.13.6, `prepended`).
        return k.built(i, .list, xs + 1, i, ks.items, flags);
    }

    /// A construction over its base (R-2.3): the base's storage is written
    /// in place, the other items are its new elements.
    /// `spread`: which items are lists whose elements go in (every one of a
    /// `++` chain); the others are elements.
    fn construction(k: *Walker, i: u32, items: []const u32, kind: Facts.DemandKind, base: u32, spread: ?[]const bool) Error!u32 {
        const fr = k.f();
        var ev: Relation.Eval = .{ .f = fr, .contracts = undefined, .arena = fr.arena };
        defer ev.deinit();
        const bv = try k.valueOf(base);
        const t_start: u32 = @intCast(k.w.leaf_runs.items.len);
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(k.gpa);
        try ev.storageOf(bv, 0, &ls);
        try k.w.leaf_runs.appendSlice(k.gpa, ls.items);
        const o_start: u32 = @intCast(k.w.value_runs.items.len);
        var ks: std.ArrayList(u32) = .empty;
        defer ks.deinit(k.gpa);
        const flags = try fr.arena.alloc(u32, items.len);
        for (items, 0..) |e, n| {
            const v = try k.valueOf(e);
            const sp = if (spread) |sps| sps[n] else true;
            flags[n] = @intFromBool(sp or e == base);
            if (e != base) try k.w.value_runs.append(k.gpa, v);
            // A spread item gives its elements, a family of unknown length.
            try ks.append(k.gpa, if (sp or e == base) try k.project(v, .plain, Step.elem.word(), 0) else v);
            try k.consume(e, i);
        }
        const pend = try k.pendingRun(i);
        try k.w.demands.append(k.gpa, .{
            .point = i,
            .kind = kind,
            .token = k.token(i),
            .base_inst = base,
            .targets = .{ .start = t_start, .len = @intCast(ls.items.len) },
            .operands = .{ .start = o_start, .len = @intCast(k.w.value_runs.items.len - o_start) },
            .pending = pend,
            .base_value = bv,
        });
        // The result is the base's storage holding every item's elements.
        return fr.mk(.{ .kind = .built, .form = .list, .site = none, .head = bv + 1, .place = try k.placeOf(i), .kids = try fr.mkKids(ks.items), .extra = flags });
    }
};

const Early = struct { v: u32, ord: u32, arg: u32, target: u32, inst: u32 };

fn concat(gpa: Allocator, a: []const u32, b: []const u32) Allocator.Error![]u32 {
    const out = try gpa.alloc(u32, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Walk `code` once (§2.12): its residue, in `w`.
pub fn walk(gpa: Allocator, arena: Allocator, account: *Ids.Account, places: *Place.Table, slots: *Slots.Table, regions: *const Regions.Tree, prepass: *const Facts.Prepass, bir: *const Bir, module: u32, ctx: Context, code: Code, atom: *u32, w: *Walk) Error!void {
    const d = code.decl;
    const n = d.inst_end.int() - d.inst_start.int();
    const nl = d.locals_end - d.locals_start;
    w.* = .{
        .f = .{ .gpa = gpa, .arena = arena, .account = account, .places = places, .slots = slots },
        .code = code,
        .bir = bir,
        .bindings = try gpa.alloc(Binding, nl),
        .regions = regions,
    };
    @memset(w.bindings, .{});
    var k: Walker = .{
        .w = w,
        .ctx = ctx,
        .bir = bir,
        .prepass = prepass,
        .gpa = gpa,
        .res = try gpa.alloc(Res, n),
        .consumer = try gpa.alloc(u32, n),
        .binds = try gpa.alloc(u32, n),
        .matches = try gpa.alloc(u32, n),
        .chain = try gpa.alloc(u32, n),
        .absorbed = try gpa.alloc(bool, n),
        .atom = atom,
        .module = module,
    };
    defer {
        gpa.free(k.res);
        gpa.free(k.consumer);
        gpa.free(k.binds);
        gpa.free(k.matches);
        gpa.free(k.chain);
        gpa.free(k.absorbed);
        k.stack.deinit(gpa);
        k.scratch.deinit(gpa);
        k.early.deinit(gpa);
    }
    @memset(k.res, .{});
    @memset(k.consumer, none);
    @memset(k.binds, none);
    @memset(k.matches, none);
    @memset(k.chain, none);
    @memset(k.absorbed, false);
    // Consumers, `let` patterns, case arms' pattern roots.
    var i = d.inst_start.int();
    while (i < d.inst_end.int()) : (i += 1) {
        k.scratch.clearRetainingCapacity();
        try bir.operands(gpa, @fromBackingInt(i), &k.scratch);
        for (k.scratch.items) |o| {
            if (o.int() < d.inst_start.int() or o.int() >= d.inst_end.int()) continue;
            k.consumer[k.rel(o.int())] = i;
        }
        switch (bir.instTag(@fromBackingInt(i))) {
            .let_pattern => k.binds[k.rel(bir.instData(@fromBackingInt(i)).rhs)] = bir.instData(@fromBackingInt(i)).lhs,
            .case => {
                const dd = bir.instData(@fromBackingInt(i));
                for (bir.extraSlice(bir.subRange(@fromBackingInt(dd.rhs)), Inst.Index)) |b| k.matches[k.rel(bir.instData(b).lhs)] = dd.lhs;
            },
            else => {},
        }
    }
    // Spread chains and the calls they absorbed; `++` chains.
    for (bir.spreads(d), 0..) |s, si| {
        if (s.root < d.inst_start.int() or s.root >= d.inst_end.int()) continue;
        k.chain[k.rel(s.root)] = @intCast(si);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        var items: std.ArrayList(u32) = .empty;
        defer items.deinit(gpa);
        for (bir.spreadItems(s)) |it| try items.append(gpa, it[0]);
        try stack.append(gpa, s.root);
        while (stack.pop()) |c| {
            if (std.mem.indexOfScalar(u32, items.items, c) != null) continue;
            if (c != s.root) k.absorbed[k.rel(c)] = true;
            switch (bir.instTag(@fromBackingInt(c))) {
                .call => {
                    k.absorbed[k.rel(bir.instData(@fromBackingInt(c)).lhs)] = true;
                    for (k.args(c)) |a| try stack.append(gpa, a.int());
                },
                .list => for (bir.extraSlice(Bir.inlineRange(bir.instData(@fromBackingInt(c))), Inst.Index)) |e| try stack.append(gpa, e.int()),
                else => {},
            }
        }
    }
    i = d.inst_start.int();
    while (i < d.inst_end.int()) : (i += 1) {
        if (bir.instTag(@fromBackingInt(i)) != .call or !ctx.isListAppend(ctx.ctx, i)) continue;
        const a = k.args(i);
        if (a.len != 2) continue;
        const inner = a[1].int();
        if (bir.instTag(@fromBackingInt(inner)) == .call and ctx.isListAppend(ctx.ctx, inner) and k.args(inner).len == 2) {
            k.absorbed[k.rel(inner)] = true;
            k.absorbed[k.rel(bir.instData(@fromBackingInt(inner)).lhs)] = true;
        }
    }
    // Parameters, then captures: the roots.
    for (code.params, 0..) |p, j| {
        const at = code.param_places[j];
        const root = try w.f.addRoot(.param, @intCast(j), at);
        const v = if (Slots.holdsAny(places, w.f.roots.items[root].path)) try w.f.refRoot(root) else try w.f.scalar();
        try k.bind(p.int(), v, p.int());
    }
    for (code.captures, 0..) |l, c| {
        const at = try ctx.placeOfLocal(ctx.ctx, l);
        const root = try w.f.addRoot(.param, @intCast(code.params.len + c), at);
        const v = if (Slots.holdsAny(places, w.f.roots.items[root].path)) try w.f.refRoot(root) else try w.f.scalar();
        w.bindings[l] = .{ .value = v, .point = code.body, .token = none };
    }
    // The instructions of this frame, in order.
    i = d.inst_start.int();
    while (i < d.inst_end.int()) : (i += 1) {
        if (!k.mine(i)) continue;
        const r = k.rel(i);
        const t = bir.instTag(@fromBackingInt(i));
        if (k.matches[r] != none) {
            try k.bind(i, try k.valueOf(k.matches[r]), i);
            continue;
        }
        if (k.absorbed[r]) continue;
        if (t.isType() or t.isPattern()) continue;
        if (code.inst != none and i == code.inst) continue;
        try account.reserve(.inspection, 1);
        if (k.chain[r] != none) {
            k.res[r] = .{ .v = try k.spreadChain(i, bir.spreads(d)[k.chain[r]]) };
        } else k.res[r] = try k.eval(i);
        const c = k.consumer[r];
        if (c != none and bir.instTag(@fromBackingInt(c)) == .let_def and bir.instData(@fromBackingInt(c)).rhs == i) {
            const def = bir.extraData(@fromBackingInt(bir.instData(@fromBackingInt(c)).lhs), Bir.LetDef);
            if (def.params_end == def.params_start) {
                try k.consume(i, i);
                try k.bindLocal(def.local, try k.valueOf(i), i, k.token(c));
            }
            continue;
        }
        if (k.binds[r] != none) {
            try k.consume(i, i);
            try k.bind(k.binds[r], try k.valueOf(i), i);
            continue;
        }
        if (c != none and bir.instTag(@fromBackingInt(c)) == .case and bir.instData(@fromBackingInt(c)).lhs == i) {
            try k.consume(i, i);
            continue;
        }
        if (k.res[r].v != none and c != none) try k.stack.append(gpa, i);
    }
    // The result: the body's value, with the early returns of `try`.
    const body = code.body;
    try k.use(body, body, .whole, .{ none, none });
    var result = try k.valueOf(body);
    var arms: std.ArrayList(u32) = .empty;
    defer arms.deinit(gpa);
    for (k.early.items) |e| {
        const target = if (e.target == none) none else e.target;
        if (target != code.inst and !(target == none and code.inst == none)) continue;
        const v = try w.f.mk(.{ .kind = .built, .form = .ctor, .head = e.ord, .place = code.result_place, .kids = try w.f.mkKids(if (e.v == none) &.{} else &.{e.v}) });
        try arms.appendSlice(gpa, &.{ @intCast(arms.items.len / 2 + 1), v });
    }
    if (arms.items.len != 0) {
        try arms.appendSlice(gpa, &.{ 0, result });
        result = try w.f.mk(.{ .kind = .alt, .head = 0x4000_0000 | body, .kids = try w.f.mkKids(arms.items) });
    }
    w.result = result;
    w.walk_calls = @intCast(w.f.calls.items.len);
    w.index = try Liveness.Index.build(gpa, account, .inference, places, regions, w.uses.items);
}

// ===========================================================================
// An evaluation (§2.10 *Read-off*, §2.11, §2.12)
// ===========================================================================

/// One evaluation of a walk under the contracts its calls read now.
pub const Evaluation = struct {
    w: *Walk,
    ev: Relation.Eval,
    contracts: *Contract.Table,
    ctx: Context,
    /// The walk's demands, then the calls' (this evaluation's).
    demands: std.ArrayList(Demand) = .empty,
    escapes: std.ArrayList(Escape) = .empty,
    /// Per frame label: the calls whose callee's label passes on to it, as
    /// `(call, callee label)` pairs, for the read-off of its supplies.
    passes: std.ArrayList([3]u32) = .empty,
    /// The group being solved, and this code's index in it (§2.12).
    solver: ?*const Group = null,
    x: u32 = none,
    /// The read-off under way (`factsOff`): later demands and escapes go
    /// into it as they are made.
    sink: Sink = undefined,
    facts_on: bool = false,

    pub fn deinit(e: *Evaluation) void {
        const g = e.w.f.gpa;
        e.ev.deinit();
        e.demands.deinit(g);
        e.escapes.deinit(g);
        e.passes.deinit(g);
        if (e.facts_on) {
            e.sink.label_at.deinit(g);
            e.sink.described.deinit(g);
        }
    }

    fn gpa(e: *Evaluation) Allocator {
        return e.w.f.gpa;
    }
    fn fr(e: *Evaluation) *Value.Frame {
        return &e.w.f;
    }
    fn account(e: *Evaluation) *Ids.Account {
        return e.w.f.account;
    }
};

/// Begin an evaluation of `w`: every call's contract read now, each
/// callee's labels mapped or applied, the calls' demands and escapes made.
pub fn evaluate(w: *Walk, contracts: *Contract.Table, ctx: Context, arena: Allocator, solver: ?*const Group, x: u32, e: *Evaluation) Error!void {
    e.* = .{ .w = w, .ev = .{ .f = &w.f, .contracts = contracts, .arena = arena }, .contracts = contracts, .ctx = ctx, .solver = solver, .x = x };
    if (solver) |sv| e.ev.live = sv.live;
    const f = &w.f;
    const gpa = f.gpa;
    try e.demands.appendSlice(gpa, w.demands.items);
    try e.escapes.appendSlice(gpa, w.escapes.items);
    // The contracts the walk's calls read now.
    for (f.calls.items[0..w.walk_calls]) |*c| {
        if (c.code != none) c.contract = (ctx.contractOf(ctx.ctx, c.code)) orelse try ctx.pessimistic(ctx.ctx, @intCast(c.args.len));
        if (c.contract == none) c.contract = try ctx.pessimistic(ctx.ctx, @intCast(c.args.len));
    }
    // A virtual call made by an earlier evaluation reads its code's contract now.
    for (f.calls.items[w.walk_calls..]) |*c| {
        if (c.code != none) c.contract = (ctx.contractOf(ctx.ctx, c.code)) orelse try ctx.pessimistic(ctx.ctx, @intCast(c.args.len));
    }
    // A construction's targets under the contracts read now.
    for (e.demands.items) |*d| if (d.base_value != none) {
        const t_start: u32 = @intCast(w.leaf_runs.items.len);
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(gpa);
        try e.ev.storageOf(d.base_value, 0, &ls);
        try w.leaf_runs.appendSlice(gpa, ls.items);
        d.targets = .{ .start = t_start, .len = @intCast(ls.items.len) };
    };
    var q: u32 = 0;
    while (q < f.calls.items.len) : (q += 1) try labelsOf(e, q);
    q = 0;
    while (q < f.calls.items.len) : (q += 1) try callEffects(e, q);
    try onceDemands(e);
}

/// The value at relative steps `words` of value `v`, by the walk's projection.
fn valueAt(e: *Evaluation, v0: u32, words: []const u32) Error!u32 {
    var k: Walker = undefined;
    _ = &k;
    const f = e.fr();
    var v = v0;
    for (words) |wd| {
        const x = f.val(v);
        const st = Step.fromWord(wd);
        v = switch (x.kind) {
            .ref => blk: {
                if (x.family != Slots.empty) break :blk try f.top();
                const p = (try f.child(x.pos, if (st.kind == .elem) .plain else .plain, wd, 0)) orelse break :blk try f.top();
                break :blk try f.mk(.{ .kind = .ref, .root = x.root, .pos = p });
            },
            .built => blk: {
                const ks = f.kidsOf(x);
                switch (x.form) {
                    .tuple => if (st.kind == .index and st.payload < ks.len) break :blk ks[st.payload],
                    .ctor => if (st.kind == .ctor_arg) {
                        const ca = f.places.ctorArgOf(st);
                        if (ca[0] == x.head and ca[1] < ks.len) break :blk ks[ca[1]];
                    },
                    .record => if (st.kind == .field) for (f.wordsOf(x.extra), 0..) |r, n| {
                        if (r == st.payload) break :blk ks[n];
                    },
                    .list => if (st.kind == .elem and ks.len == 1) break :blk ks[0],
                    else => {},
                }
                break :blk try f.top();
            },
            .scalar, .bot => return v,
            else => try f.top(),
        };
    }
    return v;
}

/// Map or apply the labels of call `q`'s callee (§2.11.3).
fn labelsOf(e: *Evaluation, q: u32) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    if (call.contract == none) return;
    const h = e.contracts.head(call.contract);
    for (e.contracts.labelsOf(h.labels), 0..) |l, li| {
        if (l.j >= call.args.len) continue;
        const arg = call.args[l.j];
        const fv = try valueAt(e, arg, f.slots.relWords(l.slot));
        const x = f.val(fv);
        if (x.kind == .built and x.form == .closure and x.head & fixed_bit == 0) {
            // A known code: a virtual call of it on the label's supplies.
            const got = try e.w.virt.getOrPut(gpa, .{ q, @intCast(li) });
            if (!got.found_existing) {
                const sig = try e.ctx.codeSig(e.ctx.ctx, x.head);
                var args: std.ArrayList(u32) = .empty;
                defer args.deinit(gpa);
                for (0..sig.own) |k| {
                    const sk = try e.w.supply_of.getOrPut(gpa, .{ q, @intCast(li), @intCast(k) });
                    if (!sk.found_existing) {
                        const si: u32 = @intCast(f.supplies.items.len);
                        const root = try f.addRoot(.supply, si, if (k < sig.params.len) sig.params[k] else .none);
                        try f.supplies.append(gpa, .{ .call = q, .label = @intCast(li), .k = @intCast(k), .root = root });
                        sk.value_ptr.* = si;
                    }
                    try args.append(gpa, try f.refRoot(f.supplies.items[sk.value_ptr.*].root));
                }
                try args.appendSlice(gpa, f.kidsOf(x));
                const vi: u32 = @intCast(f.calls.items.len);
                const root = try f.addRoot(.call, vi, sig.result);
                const kids = try f.mkKids(args.items);
                try f.calls.append(gpa, .{ .inst = call.inst, .point = call.point, .args = kids, .arg_insts = &.{}, .root = root, .code = x.head, .virtual = true, .answers = @intCast(li), .callee_val = fv });
                got.value_ptr.* = vi;
                f.calls.items[vi].contract = (e.ctx.contractOf(e.ctx.ctx, x.head)) orelse try e.ctx.pessimistic(e.ctx.ctx, @intCast(kids.len));
            }
            try e.ev.known.put(gpa, .{ q, @intCast(li) }, got.value_ptr.*);
            continue;
        }
        if (x.kind == .ref and x.family == Slots.empty and f.roots.items[x.root].kind == .param) {
            // The frame's own parameter: the label passes on (one label per
            // origin and function slot, whatever call met it).
            const slot = try f.slots.relOf(gpa, f.account, f.places, f.pos.items[x.pos].slot);
            const j = f.roots.items[x.root].a;
            const got = try e.w.derived.getOrPut(gpa, .{ j, slot, l.origin[0], l.origin[1], l.origin[2] });
            if (!got.found_existing) {
                got.value_ptr.* = @intCast(f.cbs.items.len);
                try f.cbs.append(gpa, .{ .j = j, .slot = slot, .origin = l.origin });
            }
            try e.ev.label_map.put(gpa, .{ q, @intCast(li) }, got.value_ptr.*);
            try e.passes.append(gpa, .{ got.value_ptr.*, q, @intCast(li) });
            continue;
        }
        // Unknown code: its answer is unknown, and what it is handed escapes.
        for (e.contracts.suppliesOf(l.supplies)) |s| for (e.contracts.resOf(s.res)) |rs| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            const saved = e.ev.cur_sub;
            e.ev.cur_sub = .{ .kind = .escape, .a = call.point };
            defer e.ev.cur_sub = saved;
            for (e.contracts.arrivalsOf(rs.arrivals)) |a| try supplyLeaves(e, q, a, &ls);
            e.ev.cur_sub = saved;
            for (ls.items) |lf| try addEscape(e, lf, call.point);
        };
    }
}

/// An arrival of call `q`'s supply, as leaves (`Relation.arrivalLeaves`'
/// rule, read from outside).
fn supplyLeaves(e: *Evaluation, q: u32, a: Contract.Arrival, out: *std.ArrayList(u32)) Error!void {
    const f = e.fr();
    const call = f.calls.items[q];
    switch (a.kind) {
        .param => {
            if (a.j >= call.args.len) return out.append(e.gpa(), try f.leaf(.{ .kind = .top }));
            var ps: std.ArrayList(Relation.Proj) = .empty;
            defer ps.deinit(e.gpa());
            try e.ev.project(call.args[a.j], f.slots.relWords(a.slot), true, 0, 0, &ps);
            for (ps.items) |p| try out.append(e.gpa(), p.leaf);
        },
        else => try e.ev.arrivalLeaves(q, call.contract, a, &.{}, out),
    }
}

/// The base text's instruction and the write path of argument `j` at call `q`.
fn argBase(e: *Evaluation, q: u32, j: u32) u32 {
    const f = e.fr();
    const call = f.calls.items[q];
    if (j < call.arg_insts.len and call.arg_insts[j] != none) return call.arg_insts[j];
    return call.inst;
}

/// Call `q`'s writes and escapes (§2.11.2 items 4, 5): demands and escapes.
/// A member of the group being solved gives its draft's as they stand, and
/// the rest as its draft gains them (§2.12 *Deliveries*).
fn callEffects(e: *Evaluation, q: u32) Error!void {
    const f = e.fr();
    const call = f.calls.items[q];
    if (call.contract == none) return;
    if (e.solver) |sv| if (call.code != none) if (sv.member(sv.ctx, call.code)) |m| {
        try sv.watchEffects(sv.ctx, m.x, e.x, q);
        var i: usize = 0;
        while (i < m.draft.escapes.items.len) : (i += 1) try callEscape(e, q, m.draft.escapes.items[i]);
        i = 0;
        while (i < m.draft.writes.items.len) : (i += 1) try callWrite(e, q, m.draft.writes.items[i]);
        return;
    };
    const h = e.contracts.head(call.contract);
    for (e.contracts.effectsOf(h.escapes)) |x| try callEscape(e, q, x);
    for (e.contracts.effectsOf(h.writes)) |x| try callWrite(e, q, x);
}

/// An escape of call `q`'s callee: its projections escape at the call.
pub fn callEscape(e: *Evaluation, q: u32, x: Contract.Effect) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    if (x.j >= call.args.len) return;
    var ps: std.ArrayList(Relation.Proj) = .empty;
    defer ps.deinit(gpa);
    try e.ev.project(call.args[x.j], f.slots.relWords(x.slot), true, 0, 0, &ps);
    for (ps.items) |p| try addEscapeAt(e, p.leaf, call.point, q);
}

/// A write of call `q`'s callee: a demand at the call. What it relies on
/// is instantiated once the group's facts are in (`finishDemands`).
pub fn callWrite(e: *Evaluation, q: u32, x: Contract.Effect) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    const call = f.calls.items[q];
    const site: ?CallSite = if (q < e.w.walk_calls) e.w.sites.items[q] else null;
    if (x.j >= call.args.len) return;
    const arg = call.args[x.j];
    const words = f.slots.relWords(x.slot);
    const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
    if (x.deep) {
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words, true, 0, 0, &ps);
        for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
    } else if (words.len != 0 and Step.fromWord(words[words.len - 1]).kind == .contents) {
        // A cell's `◆` (§2.13.7): the contents position of each cell the
        // argument names, whatever its contents' type.
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words[0 .. words.len - 1], false, 0, 0, &ps);
        for (ps.items) |p| {
            const l = f.leafAt(p.leaf);
            if (l.kind == .ref) if (try f.child(l.pos, .plain, Step.contents.word(), 0)) |cp| {
                const set = try f.slots.internSorted(gpa, f.account, &.{f.pos.items[cp].slot.int()});
                try e.w.leaf_runs.append(gpa, try f.leaf(.{ .kind = .ref, .root = l.root, .pos = cp, .slots = set, .tags = l.tags, .at_pos = true }));
                continue;
            };
            try e.w.leaf_runs.append(gpa, p.leaf);
        }
    } else if (words.len == 0) {
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(gpa);
        try e.ev.storageOf(arg, 0, &ls);
        try e.w.leaf_runs.appendSlice(gpa, ls.items);
    } else {
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        try e.ev.project(arg, words, false, 0, 0, &ps);
        for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
    }
    // A write of nothing (a crossing value consumed) is no demand.
    if (e.w.leaf_runs.items.len == t_start) return;
    const base = argBase(e, q, x.j);
    var write_path: PathId = .none;
    if (words.len != 0 and base != call.inst and q < e.w.walk_calls) {
        const at = try e.ctx.placeOfInst(e.ctx.ctx, base);
        var ps: std.ArrayList(u32) = .empty;
        defer ps.deinit(gpa);
        try Slots.replay(gpa, f.account, f.places, try f.places.rootPath(gpa, at), words, &ps);
        if (ps.items.len != 0) write_path = .from(ps.items[0]);
    }
    var d: Demand = .{
        .point = call.point,
        .kind = if (x.deep) .consumed else .writer,
        .token = e.w.code.decl.inst_start.int(),
        .base_inst = base,
        .write_path = write_path,
        .callee_inst = if (call.virtual) none else call.head,
        .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
        .deep = x.deep,
        .pending = if (site) |st| st.pending else .{},
        .call = q,
        .arg = x.j,
    };
    // The other arguments are its operands (§2.11.2 item 4): a write must
    // not reach what the call is also handed (`List.set b 0 (Node b)`).
    if (!call.virtual) {
        const o_start: u32 = @intCast(e.w.value_runs.items.len);
        for (call.args, 0..) |a, k| if (k != x.j) try e.w.value_runs.append(gpa, a);
        d.operands = .{ .start = o_start, .len = @intCast(e.w.value_runs.items.len - o_start) };
    }
    d.token = tokenOf(e, call.inst);
    if (call.virtual) {
        // A known code writes what a label supplies (§2.11.3): the
        // supply's distinctness condition is relied on too; a kept slot
        // refuses.
        d.callback = true;
        d.kind = .callsite;
        const outer = virtualOuter(e, q);
        if (outer) |o| {
            d.pending = e.w.sites.items[o[0]].pending;
            const oc = f.calls.items[o[0]];
            const lab = e.contracts.labelsOf(e.contracts.head(oc.contract).labels)[o[1]];
            for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == x.j) {
                for (e.contracts.effectsOf(su.kept)) |kp| if (std.mem.startsWith(u32, words, f.slots.relWords(kp.slot)) or std.mem.startsWith(u32, f.slots.relWords(kp.slot), words)) {
                    d.kept = true;
                };
            };
            d.base_inst = oc.inst;
        }
    }
    try addDemand(e, d);
}

/// What each callee write relies on (§2.11.2 item 4), instantiated on its
/// call's arguments: after the group's facts are delivered, since the
/// distinct check reads every expansion whole.
pub fn finishDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    for (0..e.demands.items.len) |di| {
        const d = &e.demands.items[di];
        if (d.call == none) continue;
        const call = f.calls.items[d.call];
        const h = e.contracts.head(call.contract);
        d.relies = try e.ev.instSel(try e.contracts.cond(e.ev.arena, h.req), d.call);
        if (!call.virtual) continue;
        const outer = virtualOuter(e, d.call) orelse continue;
        const oc = f.calls.items[outer[0]];
        const lab = e.contracts.labelsOf(e.contracts.head(oc.contract).labels)[outer[1]];
        const j = d.arg;
        for (e.contracts.suppliesOf(lab.supplies)) |su| if (su.k == j) {
            d.relies = try Cond.conj(e.ev.arena, f.account, d.relies, try e.ev.instSel(try e.contracts.cond(e.ev.arena, su.cond), outer[0]));
        };
    }
}

fn addDemand(e: *Evaluation, d: Demand) Error!void {
    try e.demands.append(e.gpa(), d);
    if (e.facts_on) try demandFacts(e, e.demands.items.len - 1);
}

fn addEscape(e: *Evaluation, leaf: u32, point: u32) Error!void {
    return addEscapeAt(e, leaf, point, none);
}

fn addEscapeAt(e: *Evaluation, leaf: u32, point: u32, call: u32) Error!void {
    try e.escapes.append(e.gpa(), .{ .leaf = leaf, .point = point, .call = call });
    if (e.facts_on) try paramEffects(&e.sink, leaf, true, .escapes);
}

/// The walk's call a virtual call applies a label of: `(call, label)`.
fn virtualOuter(e: *Evaluation, q: u32) ?[2]u32 {
    var it = e.w.virt.keys.items;
    var i: usize = 0;
    while (i + 1 < it.len) : (i += 2) {
        if (e.w.virt.values.items[i / 2] == q) return .{ it[i], it[i + 1] };
    }
    _ = &it;
    return null;
}

fn tokenOf(e: *Evaluation, inst: u32) u32 {
    return e.w.bir.insts.items(.main_token)[inst];
}

/// A closure whose code writes a capture (§2.11.4, R-2.8): a `once`
/// demand at its creation on each written capture.
fn onceDemands(e: *Evaluation) Error!void {
    const f = e.fr();
    const gpa = e.gpa();
    for (e.w.closures.items) |cl| {
        const c = (e.ctx.contractOf(e.ctx.ctx, cl.code)) orelse continue;
        const h = e.contracts.head(c);
        if (!h.flags.once) continue;
        const sig = try e.ctx.codeSig(e.ctx.ctx, cl.code);
        const x = f.val(cl.value);
        const caps = f.kidsOf(x);
        for (e.contracts.effectsOf(h.writes)) |wr| {
            if (wr.j < sig.own or wr.j - sig.own >= caps.len) continue;
            const t_start: u32 = @intCast(e.w.leaf_runs.items.len);
            var ps: std.ArrayList(Relation.Proj) = .empty;
            defer ps.deinit(gpa);
            try e.ev.project(caps[wr.j - sig.own], f.slots.relWords(wr.slot), wr.deep, 0, 0, &ps);
            for (ps.items) |p| try e.w.leaf_runs.append(gpa, p.leaf);
            try e.demands.append(gpa, .{
                .point = cl.point,
                .kind = .once,
                .token = tokenOf(e, cl.inst),
                .base_inst = cl.inst,
                .targets = .{ .start = t_start, .len = @intCast(e.w.leaf_runs.items.len - t_start) },
                .deep = wr.deep,
            });
        }
    }
}

// ---- read-off --------------------------------------------------------------

/// Where the read-off puts arrivals: the result's, or label `label`'s
/// supply `k` (an index into the draft's labels, never a pointer: the
/// lists grow while the facts are delivered).
const ResList = struct { label: u32 = none, k: u32 = 0 };
/// Where a parameter effect goes.
const EffList = enum(u8) { reads, writes, escapes };

/// The read-off's sink: a draft and the frame's labels' indices in it.
const Sink = struct {
    e: *Evaluation,
    d: *Contract.Draft,
    arena: Allocator,
    /// Per frame label (`cbs`): its index in the draft's labels.
    label_at: std.ArrayList(u32) = .empty,
    /// `(leaf, slot, list label, list k)`: a call's leaf already described
    /// there. Describing it again adds nothing, and a fold's answer that
    /// feeds itself would describe it without end.
    described: Ids.FixedDict(4) = .{},
};

fn labelIndex(s: *Sink, cb: u32) Error!u32 {
    const gpa = s.e.gpa();
    while (s.label_at.items.len <= cb) try s.label_at.append(gpa, none);
    if (s.label_at.items[cb] != none) return s.label_at.items[cb];
    const c = s.e.fr().cbs.items[cb];
    const at = try s.d.labelOf(s.arena, c.j, c.slot, c.origin);
    s.label_at.items[cb] = at;
    return at;
}

fn resList(s: *Sink, l: ResList) Error!*std.ArrayList(Contract.Draft.DraftSlot) {
    if (l.label == none) return &s.d.res;
    return &(try s.d.labels.items[l.label].supplyOf(s.arena, l.k)).res;
}

fn effList(s: *Sink, l: EffList) *std.ArrayList(Contract.Effect) {
    return switch (l) {
        .reads => &s.d.reads,
        .writes => &s.d.writes,
        .escapes => &s.d.escapes,
    };
}

/// Run `expand` for consumer `sub`: it gets what the keys hold now (in
/// `out`) and, while a group is solved, every leaf they gain later.
fn expandFor(e: *Evaluation, li: u32, sub: Relation.Sub, out: *std.ArrayList(u32)) Error!void {
    const saved = e.ev.cur_sub;
    e.ev.cur_sub = if (e.solver != null) sub else null;
    defer e.ev.cur_sub = saved;
    try e.ev.expand(li, out);
}

/// Describe value `v` at result slot `q` of the result's root into `out`
/// (§2.10 *Read-off*): what arrives at each object slot.
fn describe(s: *Sink, v: u32, q: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const Item = struct { v: u32, q: PathId };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .v = v, .q = q });
    while (stack.pop()) |it| {
        try f.charge(.inspection, 1);
        const x = f.val(it.v);
        switch (x.kind) {
            .scalar, .bot => {},
            .alt => {
                const ks = f.kidsOf(x);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) try stack.append(gpa, .{ .v = ks[i + 1], .q = it.q });
            },
            .built => {
                if (x.site != none and Slots.isObject(f.places, it.q)) try arrive(s, it.q, .{ .kind = .fresh }, out);
                if (x.form == .list and x.head != 0) {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    try e.ev.storageOf(x.head - 1, 0, &ls);
                    for (ls.items) |l| try describeLeaf(s, l, it.q, false, out);
                }
                const ks = f.kidsOf(x);
                for (ks, 0..) |kv, n| {
                    const st: ?Step = switch (x.form) {
                        .tuple => try Step.index(f.account, @intCast(n)),
                        .ctor => try f.places.ctorStep(gpa, f.account, x.head, @intCast(n)),
                        .list => Step.elem,
                        .record => try Step.field(f.account, f.wordsOf(x.extra)[n]),
                        .closure => Step.env,
                        .opaque_ => null,
                    };
                    if (st) |stp| {
                        if (try f.places.extend(gpa, f.gc(), it.q, stp)) |nq| {
                            try stack.append(gpa, .{ .v = kv, .q = nq });
                            continue;
                        }
                    }
                    // A part the result's place does not name (an opaque
                    // value's): every object of it arrives at this slot.
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    try e.ev.leavesOf(kv, 0, &ls);
                    for (ls.items) |l| try describeLeaf(s, l, it.q, true, out);
                }
            },
            .ref, .top, .shared => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try e.ev.leavesOf(it.v, 0, &ls);
                for (ls.items) |l| try describeLeaf(s, l, it.q, false, out);
            },
        }
    }
}

fn arrive(s: *Sink, q: PathId, a: Contract.Arrival, out: ResList) Error!void {
    const f = s.e.fr();
    const r = try f.slots.relOf(s.e.gpa(), f.account, f.places, q);
    const list = try resList(s, out);
    const open = f.places.kind(f.places.pathPlace(q)) == .@"var";
    if (open) try Contract.Draft.markOpen(list, s.arena, r);
    try f.charge(.edge, 1);
    if (try Contract.Draft.addArrival(list, s.arena, r, a)) {
        // A new fact of a member: delivered to what reads it (§2.12).
        if (out.label == none) if (s.e.solver) |sv| try sv.resFact(sv.ctx, s.e.x, r, open, a);
    }
}

/// A leaf at result slot `q`: its arrivals at `q` and below it. `whole`:
/// every object of it arrives at `q` itself.
fn describeLeaf(s: *Sink, li: u32, q: PathId, whole: bool, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    const l = f.leafAt(li);
    switch (l.kind) {
        .site, .fresh => try arrive(s, q, .{ .kind = .fresh }, out),
        .shared => try arrive(s, q, .{ .kind = .shared, .j = l.atom, .slot = l.extra }, out),
        .top => try arrive(s, q, .{ .kind = .top }, out),
        .answer => try arrive(s, q, .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra }, out),
        .ref => {
            const r = f.roots.items[l.root];
            const pslot = f.pos.items[l.pos].slot;
            for (f.slots.items(l.slots)) |sl| {
                // The result slot of this object: q, below by the steps from
                // the position to the slot.
                var at = q;
                if (!whole) {
                    const rel = (try f.slots.relBelow(gpa, f.account, f.places, pslot, .from(sl))) orelse Slots.root;
                    var ps: std.ArrayList(u32) = .empty;
                    defer ps.deinit(gpa);
                    try Slots.replay(gpa, f.account, f.places, q, f.slots.relWords(rel), &ps);
                    if (ps.items.len == 0) {
                        at = q;
                    } else {
                        for (ps.items[1..]) |p2| try describeOne(s, l, r, sl, .from(p2), out);
                        at = .from(ps.items[0]);
                    }
                }
                try describeOne(s, l, r, sl, at, out);
            }
        },
    }
}

fn describeOne(s: *Sink, l: Value.Leaf, r: Value.Root, sl: u32, at: PathId, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    switch (r.kind) {
        .param => {
            const deep = f.places.kind(f.places.pathPlace(.from(sl))) == .@"var";
            try arrive(s, at, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = deep }, out);
        },
        .cb => {
            const rel = (try f.slots.relBelow(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
            try arrive(s, at, .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = rel }, out);
        },
        .call, .supply => {
            const one = try f.leaf(.{ .kind = .ref, .root = l.root, .pos = l.pos, .slots = try f.slots.internSorted(gpa, f.account, &.{sl}), .tags = l.tags });
            if ((try s.described.getOrPut(gpa, .{ one, at.int(), out.label, out.k })).found_existing) return;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(gpa);
            try expandFor(e, one, .{ .kind = .describe, .a = out.label, .b = at.int(), .c = out.k, .tags = l.tags }, &ls);
            for (ls.items) |x| try describeLeaf(s, x, at, true, out);
        },
    }
}

/// The effects of leaf `li` on the frame's parameters: each parameter slot
/// it names (expanded through calls), as `(j, slot)`.
fn paramEffects(s: *Sink, li: u32, deep: bool, out: EffList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try stack.append(gpa, li);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, .{x})).found_existing) continue;
        const l = f.leafAt(x);
        if (l.kind != .ref) continue;
        const r = f.roots.items[l.root];
        switch (r.kind) {
            .param => for (f.slots.items(l.slots)) |sl| {
                const eff: Contract.Effect = .{ .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = deep };
                if (try Contract.Draft.addEffect(effList(s, out), s.arena, eff)) {
                    if (out != .reads) if (e.solver) |sv| try sv.effFact(sv.ctx, e.x, out == .writes, eff);
                }
            },
            .call, .supply => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(gpa);
                try expandFor(e, x, .{ .kind = .effect, .a = @backingInt(out), .b = @intFromBool(deep), .tags = l.tags }, &ls);
                try stack.appendSlice(gpa, ls.items);
            },
            .cb => {},
        }
    }
}

/// What `Resolve` tells the read-off: the accepted demands' reliance and
/// each direct label's kept slots and condition.
pub const Verdicts = struct {
    req: Cond = .{},
    /// Per frame label: the kept argument slots, as `(k, leaf)` pairs.
    kept: []const [3]u32 = &.{},
    /// Per frame label: the condition its supplies' check relied on.
    supply_cond: []const Cond = &.{},
};

/// A demand's written parameter slots (whatever its verdict).
fn demandFacts(e: *Evaluation, di: usize) Error!void {
    const dm = e.demands.items[di];
    for (e.w.leavesOfRun(dm.targets)) |t| try paramEffects(&e.sink, t, dm.deep, .writes);
}

/// The facts of the code's contract (§2.10 *Read-off*): its result's
/// arrivals, reads, writes, escapes and labels. While a group is solved
/// the read-off stays open: what the calls' keys gain later, and the
/// demands and escapes made later, arrive in the draft as they come.
pub fn factsOff(e: *Evaluation, arena: Allocator, d: *Contract.Draft) Error!void {
    const w = e.w;
    const f = e.fr();
    const gpa = e.gpa();
    const code = w.code;
    d.* = .{ .arity = @intCast(code.params.len + code.captures.len) };
    e.sink = .{ .e = e, .d = d, .arena = arena };
    e.facts_on = true;
    const s = &e.sink;
    const rpath = try f.places.rootPath(gpa, code.result_place);
    const rv = f.val(w.result);
    d.flags.returns = rv.kind != .bot;
    d.flags.cross = !Slots.holdsAny(f.places, rpath);
    if (d.flags.returns and !d.flags.cross) try describe(s, w.result, rpath, .{});
    // Reads: every use of a local whose value is a parameter's, at its path.
    for (w.uses.items) |u| {
        const b = w.bindings[u.local];
        if (b.value == none) continue;
        var ps: std.ArrayList(Relation.Proj) = .empty;
        defer ps.deinit(gpa);
        const lroot = try f.places.rootPath(gpa, try e.ctx.placeOfLocal(e.ctx.ctx, u.local));
        const rel = (try f.slots.relBelow(gpa, f.account, f.places, lroot, u.path)) orelse Slots.root;
        // A call use reads what its callee's footprint reads of the
        // argument (§2.10 *Read-off*, §2.11.2 item 1), not all of it.
        if (u.kind == .call and u.use_node != .none) foot: {
            const ft = w.foots.items[u.use_node.int()];
            const call = f.calls.items[ft[0]];
            if (call.contract == none) break :foot;
            const h = e.contracts.head(call.contract);
            if (h.flags.pessimistic) break :foot;
            for (e.contracts.effectsOf(h.reads)) |x| {
                if (x.j != ft[1]) continue;
                var words: std.ArrayList(u32) = .empty;
                defer words.deinit(gpa);
                try words.appendSlice(gpa, f.slots.relWords(rel));
                try words.appendSlice(gpa, f.slots.relWords(x.slot));
                var qs: std.ArrayList(Relation.Proj) = .empty;
                defer qs.deinit(gpa);
                try e.ev.project(b.value, words.items, x.deep, 0, 0, &qs);
                for (qs.items) |p| try paramEffects(s, p.leaf, x.deep, .reads);
            }
            continue;
        }
        try e.ev.project(b.value, f.slots.relWords(rel), true, 0, 0, &ps);
        for (ps.items) |p| try paramEffects(s, p.leaf, true, .reads);
    }
    // Writes: every demand's parameter targets, whatever its verdict.
    for (0..e.demands.items.len) |di| try demandFacts(e, di);
    // Escapes, deep.
    // By index: an escape made meanwhile is read off when it is made.
    const n_esc = e.escapes.items.len;
    for (0..n_esc) |i| try paramEffects(s, e.escapes.items[i].leaf, true, .escapes);
    // Labels: the direct ones with their arguments, the passed-on ones with
    // their callees' supplies.
    for (f.cbs.items, 0..) |cb, ci| {
        const at = try labelIndex(s, @intCast(ci));
        if (cb.inst != none) {
            const dl = &d.labels.items[at];
            dl.calls = if (cb.calls > 1 or dl.calls == .many) .many else if (dl.calls == .none) .once else .many;
            for (cb.args, 0..) |a, k| {
                _ = try d.labels.items[at].supplyOf(arena, @intCast(k));
                const ap = f.val(a).place;
                const root = if (ap != .none) try f.places.rootPath(gpa, ap) else rpath;
                try describe(s, a, root, .{ .label = at, .k = @intCast(k) });
            }
        }
    }
    for (e.passes.items) |p| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        const dl = &d.labels.items[at];
        dl.calls = @fromBackingInt(@intCast(@max(@backingInt(dl.calls), @backingInt(lab.calls))));
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            _ = try d.labels.items[at].supplyOf(arena, su.k);
            for (e.contracts.resOf(su.res)) |rs| {
                for (e.contracts.arrivalsOf(rs.arrivals)) |a| {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(gpa);
                    {
                        const saved = e.ev.cur_sub;
                        e.ev.cur_sub = if (e.solver != null) .{ .kind = .supply, .a = at, .b = su.k, .c = rs.slot } else null;
                        defer e.ev.cur_sub = saved;
                        try supplyLeaves(e, p[1], a, &ls);
                    }
                    for (ls.items) |l| try supplyArrive(s, l, rs.slot, .{ .label = at, .k = su.k });
                }
            }
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            for (e.contracts.effectsOf(su.kept)) |kp| _ = try Contract.Draft.addEffect(&sup.kept, arena, kp);
        }
    }
}

/// A leaf delivered to a consumer of the read-off (§2.12 *Deliveries*).
pub fn deliver(e: *Evaluation, sub: Relation.Sub, x: u32) Error!void {
    const f = e.fr();
    const y = (try f.withTags(x, sub.tags)) orelse return;
    switch (sub.kind) {
        .describe => try describeLeaf(&e.sink, y, .from(sub.b), true, .{ .label = sub.a, .k = sub.c }),
        .effect => try paramEffects(&e.sink, y, sub.b != 0, @fromBackingInt(@intCast(sub.a))),
        .supply => try supplyArrive(&e.sink, y, sub.c, .{ .label = sub.a, .k = sub.b }),
        .escape => try addEscape(e, y, sub.a),
        .forward => unreachable,
    }
}

/// The conditions of the code's contract, once its facts are in: its
/// result's separation, what its writes rely on, its labels' supplies'
/// conditions and kept slots, and `once` (§2.10 *Read-off*).
pub fn condsOff(e: *Evaluation, arena: Allocator, v: Verdicts) Error!void {
    const w = e.w;
    const f = e.fr();
    const s = &e.sink;
    const d = s.d;
    const code = w.code;
    if (d.flags.returns and !d.flags.cross) d.res_cond = try e.ev.sepOf(w.result);
    // An arrival is read where the result is consumed.
    for (d.res.items) |rs| for (rs.arrivals.items) |a| if (a.kind == .param) {
        _ = try Contract.Draft.addEffect(&d.reads, arena, .{ .j = a.j, .slot = a.slot, .deep = true });
    };
    d.req = v.req;
    for (f.cbs.items, 0..) |cb, ci| {
        if (cb.inst == none) continue;
        const at = try labelIndex(s, @intCast(ci));
        for (cb.args, 0..) |_, k| {
            const sup = try d.labels.items[at].supplyOf(arena, @intCast(k));
            if (ci < v.supply_cond.len) sup.cond = try Cond.conj(arena, f.account, sup.cond, v.supply_cond[ci]);
        }
        for (v.kept) |kp| if (kp[0] == ci) {
            const sup = try d.labels.items[at].supplyOf(arena, kp[1]);
            try paramKept(s, kp[2], &sup.kept);
        };
    }
    for (e.passes.items) |p| {
        const at = try labelIndex(s, p[0]);
        const call = f.calls.items[p[1]];
        const lab = e.contracts.labelsOf(e.contracts.head(call.contract).labels)[p[2]];
        for (e.contracts.suppliesOf(lab.supplies)) |su| {
            const sup = try d.labels.items[at].supplyOf(arena, su.k);
            sup.cond = try Cond.conj(arena, f.account, sup.cond, try e.ev.instSel(try e.contracts.cond(arena, su.cond), p[1]));
        }
    }
    // A code that writes one of its captures is `once` (R-2.8).
    for (d.writes.items) |x| if (x.j >= code.params.len) {
        d.flags.once = true;
    };
}

/// A leaf's arrivals, all at supply slot `rel`: a parameter's slots, an
/// answer's label, what a call or a supply comes from.
fn supplyArrive(s: *Sink, li: u32, rel: Slots.Rel, out: ResList) Error!void {
    const e = s.e;
    const f = e.fr();
    const gpa = e.gpa();
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var seen: Ids.FixedDict(1) = .{};
    defer seen.deinit(gpa);
    try stack.append(gpa, li);
    while (stack.pop()) |x| {
        if ((try seen.getOrPut(gpa, .{x})).found_existing) continue;
        const l = f.leafAt(x);
        const a: Contract.Arrival = switch (l.kind) {
            .site, .fresh => .{ .kind = .fresh },
            .shared => .{ .kind = .shared, .j = l.atom, .slot = l.extra },
            .top => .{ .kind = .top },
            .answer => .{ .kind = .cb, .j = try labelIndex(s, l.atom), .slot = l.extra },
            .ref => {
                const r = f.roots.items[l.root];
                switch (r.kind) {
                    .param => for (f.slots.items(l.slots)) |sl| {
                        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(gpa, f.account, f.places, .from(sl)), .deep = f.places.kind(f.places.pathPlace(.from(sl))) == .@"var" });
                    },
                    .cb => for (f.slots.items(l.slots)) |sl| {
                        const below = (try f.slots.relBelow(gpa, f.account, f.places, r.path, .from(sl))) orelse Slots.root;
                        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, .{ .kind = .cb, .j = try labelIndex(s, r.a), .slot = below });
                    },
                    .call, .supply => {
                        var ls: std.ArrayList(u32) = .empty;
                        defer ls.deinit(gpa);
                        try expandFor(e, x, .{ .kind = .supply, .a = out.label, .b = out.k, .c = rel, .tags = l.tags }, &ls);
                        try stack.appendSlice(gpa, ls.items);
                    },
                }
                continue;
            },
        };
        _ = try Contract.Draft.addArrival(try resList(s, out), s.arena, rel, a);
    }
}

/// A kept supply leaf as slots of the supply (relative to its own root).
fn paramKept(s: *Sink, li: u32, out: *std.ArrayList(Contract.Effect)) Error!void {
    const f = s.e.fr();
    const l = f.leafAt(li);
    if (l.kind != .ref) {
        _ = try Contract.Draft.addEffect(out, s.arena, .{ .j = 0, .slot = Slots.root, .deep = true });
        return;
    }
    const pslot = f.pos.items[l.pos].slot;
    for (f.slots.items(l.slots)) |sl| {
        const rel = (try f.slots.relBelow(s.e.gpa(), f.account, f.places, pslot, .from(sl))) orelse Slots.root;
        _ = try Contract.Draft.addEffect(out, s.arena, .{ .j = 0, .slot = rel, .deep = false });
    }
}

// ===========================================================================
// The group an evaluation is in (§2.12 step 2)
// ===========================================================================

/// The group being solved, as its evaluations see it: its members' drafts,
/// and where their new facts go. `Deliver.Solver` implements it.
pub const Group = struct {
    ctx: *anyopaque,
    live: *Relation.Live,
    /// Code `code`'s index and draft when it is a member, else null.
    member: *const fn (ctx: *anyopaque, code: u32) ?Member,
    /// Evaluation `y`'s call `call` of member `x` gets `x`'s later writes and escapes.
    watchEffects: *const fn (ctx: *anyopaque, x: u32, y: u32, call: u32) Error!void,
    /// Member `x` gained arrival `a` at result slot `rel`.
    resFact: *const fn (ctx: *anyopaque, x: u32, rel: Slots.Rel, open: bool, a: Contract.Arrival) Error!void,
    /// Member `x` gained a write (or an escape).
    effFact: *const fn (ctx: *anyopaque, x: u32, write: bool, eff: Contract.Effect) Error!void,

    pub const Member = struct { x: u32, draft: *Contract.Draft };
};
