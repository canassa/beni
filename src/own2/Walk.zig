//! L6: one walk of one code (`docs/design/ownership-v2.md` §2.6, §2.7).
//!
//! **The walk** goes over a code's instructions once, in their order (the
//! BIR numbers an operand before its consumer): a rule per tag (§2.6) gives
//! each instruction its value (§2.3.3), records the uses of locals at their
//! consumers (§2.7), the pending operands, the escapes, the demands of
//! constructions and `++` chains, and every call as a record whose result is
//! a root of its own. Nothing the walk does reads a callee's contract: a
//! call's leaves are expanded only by an evaluation (`Eval`). So a recursive
//! group's members are walked once each (§2.12), whatever their candidates.
//!
//! Obligations kept here: O2's use half (a use is recorded at its consumer,
//! at its path, with its kind).

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
    /// The codes of the declarations a dispatch site at `inst` passes as
    /// evidence (appended, each once).
    evidenceCodes: *const fn (ctx: *anyopaque, inst: u32, out: *std.ArrayList(u32)) Error!void,
    /// The code of a lambda or a local function's `let_def`.
    codeOf: *const fn (ctx: *anyopaque, inst: u32) ?u32,
    /// A code's captures (declaration-relative locals, sorted).
    capturesOf: *const fn (ctx: *anyopaque, code: u32) []const u32,
    /// A code's current contract, or null.
    contractOf: *const fn (ctx: *anyopaque, code: u32) ?Contract.Id,
    /// A code's places: its parameters' (own, then captures) and its result's.
    codeSig: *const fn (ctx: *anyopaque, code: u32) Error!Sig,
    /// The places of the function type instruction `inst` has at its site:
    /// its parameters' appended, its result's returned; null when it has
    /// no function type.
    siteSig: *const fn (ctx: *anyopaque, inst: u32, params: *std.ArrayList(PlaceId)) Error!?PlaceId,
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
    /// A `once` demand's written capture: the base is this local, not
    /// `base_inst` (`none` otherwise).
    base_local: u32 = none,
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
    /// A `once` code's capture written where it may run again: refused `once`.
    many: bool = false,
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
            // A record update's base waits for a consumer that touches it
            // at every field but the updated ones (§2.6's `record_update`
            // row, §2.8 *Dead*): it holds only those fields' values.
            const c = k.consumer[k.rel(i)];
            if (c != none and k.bir.instTag(@fromBackingInt(c)) == .record_update and k.bir.instData(@fromBackingInt(c)).lhs == i) {
                const fields = k.bir.extraSlice(k.bir.subRange(@fromBackingInt(k.bir.instData(@fromBackingInt(c)).rhs)), Bir.Field);
                for (k.f().places.steps(try k.placeOf(c)).steps) |st| {
                    if (st.kind != .field) continue;
                    const updated = for (fields) |fl| {
                        if (k.ctx.fieldRank(k.ctx.ctx, fl.name) == st.payload) break true;
                    } else false;
                    if (updated) continue;
                    try k.w.pending_runs.append(k.gpa, .{ .value = try k.project(v, .plain, st.word(), 0), .inst = i });
                }
                continue;
            }
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
                try k.evidence(i);
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
                try k.evidence(i);
                if (k.ctx.isListAppend(k.ctx.ctx, i) and k.args(i).len == 2) return .{ .v = try k.appendChain(i) };
                var all: std.ArrayList(u32) = .empty;
                defer all.deinit(k.gpa);
                for (k.args(i)) |a| try all.append(k.gpa, a.int());
                return .{ .v = try k.call(i, d.lhs, all.items) };
            },
            .method_call => {
                try k.evidence(i);
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
            if (b.value != none) try k.captureUse(l, i);
        }
        const v = try k.built(i, .closure, code, if (code & fixed_bit == 0) i else none, ks.items, &.{});
        if (code & fixed_bit == 0) try k.w.closures.append(k.gpa, .{ .code = code, .value = v, .point = i, .inst = i });
        return v;
    }

    /// The declarations a dispatch site passes as evidence: function values
    /// handed to code the checker does not see, so each escapes at the
    /// site (§2.11.4), and a parameter it writes is refused there.
    fn evidence(k: *Walker, i: u32) Error!void {
        var codes: std.ArrayList(u32) = .empty;
        defer codes.deinit(k.gpa);
        try k.ctx.evidenceCodes(k.ctx.ctx, i, &codes);
        for (codes.items) |c| try k.escapeValue(try k.closureOf(i, c, &.{}), i);
    }

    fn captureUse(k: *Walker, l: u32, i: u32) Error!void {
        const at = try k.placeOfLocal(l);
        k.atom.* += 1;
        try k.w.uses.append(k.gpa, .{ .local = l, .path = try k.f().places.rootPath(k.gpa, at), .point = i, .kind = .whole, .region = k.w.regions.regionOf(i), .use_node = .none, .atom = k.atom.* });
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
                // A function value called reads what its closure holds.
                if (head != none) {
                    try k.use(head, i, .whole, .{ none, none });
                    k.pop(head);
                }
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
                    // The call reads the captures it runs with (§2.11.4).
                    if (b.value != none) try k.captureUse(l, i);
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
        // Bound where the parameters are, before every point of the
        // body: a capture written and read again later is `later-use`.
        w.bindings[l] = .{ .value = v, .point = if (code.params.len != 0) code.params[0].int() else code.body, .token = none };
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
