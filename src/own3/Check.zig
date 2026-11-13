//! own3, layer 4: one module (`ownership-v3-kernel.md` §7; research report
//! 110 §6.7; report 111 §2).
//!
//! The declarations of a module are walked in dependency order, callees
//! first (`own2/Prepass.zig` gives the groups). A group that calls itself is
//! walked again until no contract of it changes: the contracts start empty
//! and only grow, so the last round's verdicts stand on the least fixed
//! point. A declaration with ownership words is not walked: its words are
//! its contract (`wordedContract`). A `foreign` with no word has no contract,
//! and so has a declaration whose walk gave up: a call of either lets each
//! argument escape, and its answer can hold each argument.
//!
//! The place graph is `own2/Place.zig`'s, read through `own2/Groups.zig`'s
//! adapter. Nothing else of the ownership checker v2 runs here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Ast = @import("../parse/Ast.zig");
const Ids = @import("../own2/Ids.zig");
const Place = @import("../own2/Place.zig");
const Groups = @import("../own2/Groups.zig");
const Prepass = @import("../own2/Prepass.zig");
const Facts = @import("../own2/Facts.zig");
const Message = @import("../own2/Message.zig");
const InternPool = @import("../InternPool.zig");
const Loc = @import("Loc.zig");
const Contract = @import("Contract.zig");
const Frame = @import("Frame.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Edges = @import("../check/Edges.zig");

const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Inst = Bir.Inst;
const Var = TypeStore.Var;
const Src = Contract.Src;
const W = Ast.OwnWord;
const none = Loc.none;

pub const Names = Message.Names;

/// What the modules of one run share: each module's contracts, written once
/// by the worker that checked it, before any importer runs.
pub const Shared = struct {
    published: []?*Contract.Published,
};

pub const Line = struct {
    /// The instruction the lowering channel names, and the token of the position.
    inst: u32,
    token: u32,
    kind: Facts.DemandKind,
    op: []const u8,
    base: []const u8,
    refused: bool,
    accepted: Facts.Verdict.Accepted = .fresh,
    cause: Facts.Cause = .unknown,
    detail: []const u8 = "",
};

pub const Result = struct {
    lines: []const Line,
    published: *Contract.Published,
    /// Declarations that the walk gave up on (a nesting too deep, a group that did not settle).
    limits: []const []const u8,
    /// Each declaration's contract as text, when asked for.
    summaries: []const []const u8,
};

/// The build's markup type (`boundary.md` §9.2), by the names the manifest
/// gives: a function of an entry's record that answers it is a `view`, and
/// what its answer holds is rendered before the runtime runs `update` again
/// (`boundary.md` §9.4.8, kernel §6.12).
pub const MarkupType = struct { module: InternPool.Symbol, name: InternPool.Symbol };

pub const Options = struct { summaries: bool = false, markup_type: ?MarkupType = null };

const State = enum(u8) { todo, working, done };

pub const Mod = struct {
    gpa: Allocator,
    /// Lives as long as the module's result.
    arena: Allocator,
    walk_arena: std.heap.ArenaAllocator,
    in: *const Groups.Input,
    bir: *const Bir,
    tags: []const Inst.Tag,
    datas: []const Inst.Data,
    tokens: []const u32,
    names: Names,
    shared: *const Shared,
    /// The build's markup type, when it has one (`Options.markup_type`).
    markup_type: ?MarkupType = null,

    places: Place.Table = .{},
    account: Ids.Account = .{ .allowance = std.math.maxInt(u32) },
    adapter: Groups.Adapter = undefined,
    loc: Loc.Table = undefined,
    prepass: Facts.Prepass = undefined,
    var_place: PlaceId = undefined,

    next_frame: u32 = 1,
    /// Per local of the module: its value and its frame, while its declaration is walked.
    lv: []Frame.Val = &.{},
    lframe: []u32 = &.{},
    /// Per local of the module: the frame whose `let` binds it, set where
    /// that frame enters the `let` (`Frame.enterLet`). A local that a frame
    /// names before it is bound is the frame's own (a later binding of its
    /// own `let`) or a capture (a later binding of an enclosing frame's).
    lbinder: []u32 = &.{},
    /// Per local of the module: the binding of a local function, or of a
    /// value whose right side is a lambda (a code binding), or `none`.
    lcode: []u32 = &.{},
    /// Per local of the module: the cyclic group of code bindings that it is
    /// in, an index of `groups`, or `none`.
    lgroup: []u32 = &.{},
    /// Per local of the module: scratch for `Frame.findGroups`, `none` outside it.
    lindex: []u32 = &.{},
    /// The cyclic groups of code bindings: their bindings, in written order.
    groups: std.ArrayList([]const u32) = .empty,
    /// Per `let` instruction: its code bindings and groups are known.
    let_seen: std.DynamicBitSetUnmanaged = .{},
    /// Per code instruction: a walk named the code while its rounds ran
    /// (`Frame.memberValue`), so its contract so far was read.
    recalled: []bool = &.{},
    /// Per instruction: the contract of the lambda or local function there.
    code_contract: []?*const Contract.Contract = &.{},
    /// Per instruction: the locals that the code there captured in its last
    /// walk, in the order of its contract's parameters after its own.
    code_caps: [][]const u32 = &.{},
    contracts: []?*const Contract.Contract = &.{},
    /// Per declaration: its last walk gave up, so it must publish no contract (kernel §3.3; asserted at `publish`).
    failed_decl: []bool = &.{},
    /// The contracts of a group whose rounds run (`solveGroup`,
    /// `Frame.solveCodes`): a fresh cell of one of them is named by the call
    /// alone (`Frame.freshAtom`), so the rounds settle (kernel §4.2).
    drafts: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// The allocation sites of this module's contracts: a small number for
    /// each site name, the same in each round (`siteId`).
    sites: std.AutoHashMapUnmanaged(u64, u16) = .empty,
    state: []State = &.{},
    worded_done: []bool = &.{},
    readers: []?Contract.Reader = &.{},
    spread_root: std.DynamicBitSetUnmanaged = .{},
    lines: std.ArrayList(Line) = .empty,
    limits: std.ArrayList([]const u8) = .empty,

    // ---- types ------------------------------------------------------------------

    pub fn placeOf(m: *Mod, v: Var.Optional) Allocator.Error!PlaceId {
        return m.adapter.placeOfVar(v) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // A type past a limit of the place graph: it holds anything.
            else => blk: {
                m.account.failed = null;
                break :blk m.var_place;
            },
        };
    }

    pub fn typeOfInst(m: *const Mod, inst: u32) Var.Optional {
        return if (inst < m.in.inst_type.len) m.in.inst_type[inst] else .none;
    }

    pub fn typeOfLocal(m: *const Mod, d: Bir.Decl, local: u32) Var.Optional {
        const l = d.locals_start + local;
        return if (l < m.in.local_type.len) m.in.local_type[l] else .none;
    }

    pub fn placeOfInst(m: *Mod, inst: u32) Allocator.Error!PlaceId {
        return m.placeOf(m.typeOfInst(inst));
    }

    pub fn placeOfLocal(m: *Mod, d: Bir.Decl, local: u32) Allocator.Error!PlaceId {
        return m.placeOf(m.typeOfLocal(d, local));
    }

    pub fn fnType(m: *const Mod, v: Var.Optional) ?TypeStore.Structure.Func {
        const t = v.unwrap() orelse return null;
        return switch (m.in.store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .func => |f| f,
                else => null,
            },
            else => null,
        };
    }

    /// Whether a value of type `v` is the build's markup: an application of
    /// the type the manifest names (`Options.markup_type`). The type is the
    /// platform's row; no declaration is read by its name (kernel §6.11).
    pub fn isMarkup(m: *const Mod, v: Var.Optional) bool {
        const mt = m.markup_type orelse return false;
        const t = v.unwrap() orelse return false;
        switch (m.in.store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .app => |a| {
                    const id = a.type.int();
                    if (id >= m.in.types.entries.len) return false;
                    const e = m.in.types.entries[id];
                    return e.package == .platform and e.module_name == mt.module and e.name == mt.name;
                },
                else => return false,
            },
            else => return false,
        }
    }

    /// Whether a value of type `v` is what a `view` answers: markup, or a
    /// record or tuple with markup in it whose other parts hold no cell
    /// (`Tea.Document`'s title and body). The runtime renders such a value
    /// whole, and keeps none of it (`boundary.md` §9.4.8).
    pub fn isView(m: *Mod, v: Var.Optional, depth: u32) Allocator.Error!bool {
        if (m.isMarkup(v)) return true;
        if (depth >= 4) return false;
        const t = v.unwrap() orelse return false;
        const store = m.in.store;
        const parts: []const Var = switch (store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .tuple => |r| store.vars(r),
                .record => |rec| blk: {
                    // A closed record: its fields, with no extension.
                    switch (store.resolvedContent(rec.ext)) {
                        .structure => |es| if (es != .empty_record) return false,
                        else => return false,
                    }
                    const fs = store.fields(rec.fields);
                    const out = try m.walk_arena.allocator().alloc(Var, fs.len);
                    for (out, fs) |*o, fld| o.* = fld.value;
                    break :blk out;
                },
                else => return false,
            },
            else => return false,
        };
        var markup = false;
        for (parts) |p| {
            if (try m.isView(p.toOptional(), depth + 1)) {
                markup = true;
            } else if (m.loc.layouts.items[try m.loc.layoutOf(try m.placeOf(p.toOptional()))].len != 0) return false;
        }
        return markup;
    }

    /// Whether a function parameter of type `v` is the runtime's `send`: an
    /// alias with the word `sender` (`pub sender type alias Send msg = msg →
    /// ⊤`, ownership-v2.md §2.13.5), which a platform puts on it. The word
    /// is the row; no name is read (kernel §6.11).
    pub fn isSender(m: *const Mod, v: Var.Optional) bool {
        const t = v.unwrap() orelse return false;
        const store = m.in.store;
        switch (store.content(store.find(t))) {
            .alias => |a| {
                const id = a.type.int();
                if (id >= m.in.types.entries.len) return false;
                const e = m.in.types.entries[id];
                if (e.package == .app) return false;
                return m.aliasIsSender(.{ e.module.int(), e.decl.int() }, 0);
            },
            else => return false,
        }
    }

    /// Whether the type alias at `t` has the word `sender`, or is an alias of
    /// one that has it (`Cmd.Send msg = Browser.Send msg`): its body is a
    /// reference to another alias, followed to the declaration.
    fn aliasIsSender(m: *const Mod, t: [2]u32, depth: u32) bool {
        if (depth > 8 or t[0] >= m.in.birs.len) return false;
        const owner = m.in.birs[t[0]];
        if (t[1] >= owner.decls.len) return false;
        const d = owner.decls[t[1]];
        if (d.own_kind == .sender) return true;
        var body = (d.annotation.unwrap() orelse return false).int();
        if (owner.instTag(@fromBackingInt(body)) == .type_app) body = owner.instData(@fromBackingInt(body)).lhs;
        const data = owner.instData(@fromBackingInt(body));
        return switch (owner.instTag(@fromBackingInt(body))) {
            .type_top => m.aliasIsSender(.{ t[0], data.lhs }, depth + 1),
            .ext_type => if (data.lhs < m.in.provenance.len) (if (m.in.provenance[data.lhs].typeDecl(data.rhs)) |td| m.aliasIsSender(.{ data.lhs, td.int() }, depth + 1) else false) else false,
            else => false,
        };
    }

    pub fn ctorStep(m: *Mod, ordinal: u32, k: u32) Allocator.Error!Step {
        return m.places.ctorStep(m.gpa, &m.account, ordinal, k) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => blk: {
                m.account.failed = null;
                break :blk Step.level;
            },
        };
    }

    pub fn fieldRank(m: *const Mod, s: Bir.SymbolIndex) u32 {
        return m.adapter.rank(m.bir.symbol(s));
    }

    pub fn symbolText(m: *const Mod, s: Bir.SymbolIndex) []const u8 {
        return m.names.interner.slice(m.bir.symbol(s));
    }

    /// The location of a place's own cell.
    pub fn selfLoc(m: *Mod, place: PlaceId) Allocator.Error!u32 {
        return m.loc.selfLoc(place);
    }

    /// The allocation site number of the site named `name` in a contract of
    /// this module (kernel §4.2): the same number for the same name, in every
    /// round of a group.
    pub fn siteId(m: *Mod, name: u64) Allocator.Error!u16 {
        const got = try m.sites.getOrPut(m.gpa, name);
        if (!got.found_existing) got.value_ptr.* = @intCast(@min(m.sites.count() - 1, std.math.maxInt(u16)));
        return got.value_ptr.*;
    }

    pub fn isDraft(m: *const Mod, c: *const Contract.Contract) bool {
        return m.drafts.contains(@intFromPtr(c));
    }

    // ---- names of the program --------------------------------------------------

    pub const CtorInfo = struct { ordinal: u32, arity: u32 };

    /// The module and the constructor that the reference `ref` names.
    fn ctorAt(m: *const Mod, ref: u32) ?[2]u32 {
        const d = m.datas[ref];
        const at: [2]u32 = switch (m.tags[ref]) {
            .ctor => .{ m.in.module, d.lhs },
            .ext_ctor => if (d.lhs < m.in.provenance.len and d.rhs < m.in.provenance[d.lhs].ctor_index.len) .{ d.lhs, m.in.provenance[d.lhs].ctor_index[d.rhs] } else return null,
            else => return null,
        };
        if (at[0] >= m.in.birs.len or at[1] >= m.in.birs[at[0]].ctors.len) return null;
        return at;
    }

    pub fn ctorInfo(m: *const Mod, ref: u32) ?CtorInfo {
        const at = m.ctorAt(ref) orelse return null;
        const owner = m.in.birs[at[0]];
        const c = owner.ctors[at[1]];
        return .{ .ordinal = at[1] - owner.decl(c.decl).ctors_start, .arity = @backingInt(c.args_end) - @backingInt(c.args_start) };
    }

    /// The step from a value that the constructor `ref` makes to its
    /// argument `k`: the constructor's argument, or, for a record alias's
    /// constructor, the field that its argument `k` is (the fields in the
    /// order the alias writes them; backend.md §4: the constructor builds
    /// the record). Null when neither describes it.
    pub fn ctorArgStep(m: *Mod, ref: u32, place: PlaceId, k: u32) Allocator.Error!?Step {
        const info = m.ctorInfo(ref) orelse return null;
        if (k >= info.arity) return null;
        switch (m.places.kind(place)) {
            .ctor => return try m.ctorStep(info.ordinal, k),
            .record => {
                const at = m.ctorAt(ref).?;
                const owner = m.in.birs[at[0]];
                const body = owner.decl(owner.ctors[at[1]].decl).annotation.unwrap() orelse return null;
                if (owner.instTag(body) != .type_record) return null;
                const fields = owner.extraSlice(Bir.inlineRange(owner.instData(body)), Bir.Field);
                if (fields.len != info.arity) return null;
                return .{ .kind = .field, .payload = @intCast(m.adapter.rank(owner.symbol(fields[k].name))) };
            },
            else => return null,
        }
    }

    /// The step from the scrutinee of a `try` to the value that it has when
    /// it succeeds: the argument of `Ok` or `Just`, each its type's first
    /// constructor (language.md §6.6). Null for another type.
    pub fn trySuccess(m: *Mod, scrut: u32) Allocator.Error!?Step {
        const at = try m.placeOfInst(scrut);
        if (m.places.kind(at) != .ctor) return null;
        const head = m.places.head(at);
        const wk = m.in.types.well_known;
        if (head != wk.result.int() and head != wk.maybe.int()) return null;
        return try m.ctorStep(0, 0);
    }

    /// The declaration a reference runs, aliases followed.
    pub fn calleeOf(m: *const Mod, inst: u32) ?[2]u32 {
        const d = m.datas[inst];
        var t: [2]u32 = switch (m.tags[inst]) {
            .top => .{ m.in.module, d.lhs },
            .ext_value => blk: {
                if (d.lhs >= m.in.provenance.len) return null;
                const decl = m.in.provenance[d.lhs].valueDecl(d.rhs) orelse return null;
                break :blk .{ d.lhs, decl.int() };
            },
            else => return null,
        };
        var budget: u32 = 16;
        while (budget > 0) : (budget -= 1) t = Prepass.aliasStep(m.in.birs, m.in.provenance, t) orelse break;
        return t;
    }

    pub fn methodTarget(m: *const Mod, inst: u32) ?[2]u32 {
        const dt = m.in.dispatch orelse return null;
        const site = dt.siteOf(@fromBackingInt(inst)) orelse return null;
        const ti = site.callee.unwrap() orelse return null;
        return switch (dt.term(ti)) {
            .top => |u| .{ m.in.module, u.decl.int() },
            .ext => |u| if (m.in.provenance.len > u.module.int()) (if (m.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| .{ u.module.int(), d.int() } else null) else null,
            else => null,
        };
    }

    pub fn isListAppend(m: *const Mod, inst: u32) bool {
        const dt = m.in.dispatch orelse return false;
        return dt.isListAppend(@fromBackingInt(inst)) or dt.isListAppend(@fromBackingInt(m.datas[inst].lhs));
    }

    pub fn spreadOf(m: *const Mod, d: Bir.Decl, inst: u32) ?Bir.Spread {
        if (inst >= m.spread_root.bit_length or !m.spread_root.isSet(inst)) return null;
        for (m.bir.spreads(d)) |s| if (s.root == inst) return s;
        return null;
    }

    fn declOf(m: *const Mod, t: [2]u32) ?Bir.Decl {
        if (t[0] >= m.in.birs.len or t[1] >= m.in.birs[t[0]].decls.len) return null;
        return m.in.birs[t[0]].decls[t[1]];
    }

    /// Where a function of an entry's record has the model, read off the
    /// entry's declared type (kernel §6.13): the model is the type variable
    /// of `update`'s last parameter.
    pub const EntryField = struct {
        name: InternPool.Symbol,
        /// The field's declared type is a function, of this many parameters.
        is_fn: bool,
        arity: u32 = 0,
        /// The parameter that is the model, or `none`.
        model_param: u32 = none,
        /// Where the answer has the model: `none` (it has none), `whole` (the
        /// answer is the model), `index` (the item `index` of a tuple).
        answer: enum { none, whole, index } = .none,
        index: u32 = 0,
        /// The model is in a parameter or the answer in another shape: no
        /// fact says where, and the entry has none of its lists `own`.
        unknown: bool = false,
    };

    /// The fields of the record that the entry `t` takes (its first
    /// parameter), or null where the declared type is not one that this
    /// reads (no fact: the caller takes no location as `own`).
    pub fn entryShape(m: *Mod, t: [2]u32) Allocator.Error!?[]const EntryField {
        const d = m.declOf(t) orelse return null;
        const bir = m.in.birs[t[0]];
        const ann = d.annotation.unwrap() orelse return null;
        if (bir.instTag(ann) != .type_fn) return null;
        const ps = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(ann).lhs)), Inst.Index);
        if (ps.len == 0 or bir.instTag(ps[0]) != .type_record) return null;
        const fields = bir.extraSlice(Bir.inlineRange(bir.instData(ps[0])), Bir.Field);
        const interner = m.in.interner orelse return null;
        const update_sym = interner.find("update") orelse return null;
        // The model: the type variable of `update`'s last parameter.
        var model: ?InternPool.Symbol = null;
        for (fields) |fd| if (bir.symbol(fd.name) == update_sym and bir.instTag(fd.value) == .type_fn) {
            const up = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(fd.value).lhs)), Inst.Index);
            if (up.len != 0 and bir.instTag(up[up.len - 1]) == .type_var) model = bir.symbol(@fromBackingInt(bir.instData(up[up.len - 1]).lhs));
        };
        const mv = model orelse return null;
        const out = try m.walk_arena.allocator().alloc(EntryField, fields.len);
        for (fields, out) |fd, *o| {
            o.* = .{ .name = bir.symbol(fd.name), .is_fn = bir.instTag(fd.value) == .type_fn };
            if (!o.is_fn) {
                if (try m.mentionsVar(bir, fd.value, mv)) o.unknown = true;
                continue;
            }
            const fps = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(fd.value).lhs)), Inst.Index);
            o.arity = @intCast(fps.len);
            for (fps, 0..) |p, k| {
                if (isVar(bir, p, mv)) {
                    if (o.model_param != none) o.unknown = true;
                    o.model_param = @intCast(k);
                } else if (try m.mentionsVar(bir, p, mv)) o.unknown = true;
            }
            const r: Inst.Index = @fromBackingInt(bir.instData(fd.value).rhs);
            if (isVar(bir, r, mv)) {
                o.answer = .whole;
            } else if (bir.instTag(r) == .type_tuple) {
                for (bir.extraSlice(Bir.inlineRange(bir.instData(r)), Inst.Index), 0..) |item, k| {
                    if (isVar(bir, item, mv)) {
                        if (o.answer != .none) o.unknown = true;
                        o.answer = .index;
                        o.index = @intCast(k);
                    } else if (try m.mentionsVar(bir, item, mv)) o.unknown = true;
                }
            } else if (try m.mentionsVar(bir, r, mv)) o.unknown = true;
        }
        return out;
    }

    fn isVar(bir: *const Bir, t: Inst.Index, v: InternPool.Symbol) bool {
        return bir.instTag(t) == .type_var and bir.symbol(@fromBackingInt(bir.instData(t).lhs)) == v;
    }

    /// Whether the type written at `t` names the type variable `v`.
    fn mentionsVar(m: *Mod, bir: *const Bir, t: Inst.Index, v: InternPool.Symbol) Allocator.Error!bool {
        if (isVar(bir, t, v)) return true;
        var ops: std.ArrayList(Inst.Index) = .empty;
        defer ops.deinit(m.gpa);
        try bir.operands(m.gpa, t, &ops);
        for (ops.items) |o| if (try m.mentionsVar(bir, o, v)) return true;
        return false;
    }

    pub fn isWorded(m: *const Mod, t: [2]u32) bool {
        const d = m.declOf(t) orelse return false;
        return m.in.birs[t[0]].ownSlotsV2(d).len != 0;
    }

    /// Whether the declaration is a function: a reference to it is a function value.
    pub fn isFunction(m: *Mod, t: [2]u32) Allocator.Error!bool {
        const d = m.declOf(t) orelse return false;
        if (!d.kind.isValue()) return false;
        if (d.params != 0) return true;
        const body = d.body.unwrap() orelse return false;
        return m.in.birs[t[0]].instTag(body) == .lambda;
    }

    /// The contract of declaration `t`, or null when nothing is known of it.
    pub fn declContract(m: *Mod, t: [2]u32) Allocator.Error!?*const Contract.Contract {
        if (t[0] != m.in.module) {
            if (t[0] >= m.readers.len) return null;
            if (m.readers[t[0]] == null) {
                const from = m.shared.published[t[0]] orelse return null;
                m.readers[t[0]] = try Contract.Reader.init(m.arena, from);
            }
            return m.readers[t[0]].?.contract(m.gpa, m.arena, &m.loc, t[1]);
        }
        const d = m.bir.decls[t[1]];
        if (!d.kind.isValue()) return null;
        if (m.bir.ownSlotsV2(d).len != 0) {
            if (!m.worded_done[t[1]]) {
                m.worded_done[t[1]] = true;
                m.contracts[t[1]] = try m.wordedContract(t[1]);
            }
            return m.contracts[t[1]];
        }
        return m.contracts[t[1]];
    }

    // ---- code that the walk does not follow --------------------------------------

    /// What the code that dispatch edge `e` names can do with a value it is
    /// handed (kernel §6.11): write it, keep it, or nothing that a contract
    /// says (`no_contract`: unknown code, which keeps what it is handed).
    /// The code is called by code that the walk does not follow — a
    /// function the compiler derives, or code handed evidence — so the fact
    /// is read off the callee's contract, never off its name, and a missing
    /// fact is the pessimistic one: another module's derived method with no
    /// published fact can write and keep.
    pub fn edgeEffect(m: *Mod, e: Edges.Edge) Allocator.Error!Contract.Effect {
        const target: [2]u32 = switch (e) {
            .top => |d| .{ m.in.module, d },
            .ext => |x| blk: {
                if (x.module.int() >= m.in.provenance.len) return .{ .no_contract = true };
                const d = m.in.provenance[x.module.int()].valueDecl(x.value) orelse return .{ .no_contract = true };
                break :blk .{ x.module.int(), d.int() };
            },
            // This module's row: its body is walked with the edges (`through_rows`).
            .derived => return .{},
            .ext_derived => |u| {
                const owner = m.in.types.entries[@backingInt(u.type)].module;
                for ([_]u32{ u.module.int(), owner.int() }) |mi| {
                    if (mi >= m.shared.published.len) continue;
                    const p = m.shared.published[mi] orelse continue;
                    for (p.derived) |fact| if (fact.type == @backingInt(u.type) and fact.kind == @backingInt(u.kind)) return fact.effect;
                }
                return .{ .writes = true, .keeps = true, .no_contract = true };
            },
            // The compiler's own comparisons and codecs: they read their
            // operands; what they call is an edge of its own.
            .primitive, .undetermined, .codec => return .{},
        };
        if (try m.declContract(target)) |c| return .{ .writes = c.writes(), .keeps = c.escapes() };
        if (try m.isFunction(target)) return .{ .no_contract = true };
        return .{};
    }

    /// The text of a refusal of evidence with effect `x` (`Frame.evidence`).
    pub fn evidenceText(x: Contract.Effect) []const u8 {
        if (x.writes) return "a function that writes its parameter is handed as evidence";
        if (x.keeps) return "a function that keeps its parameter is handed as evidence";
        return "a function with no contract is handed as evidence";
    }

    /// Every edge of the terms `roots`, through the body of each derived
    /// row of this module that they name, each term once (`Edges.termsEdges`):
    /// the methods a derived `eq` or `compare` calls on the parts of its
    /// type, at any depth, and the evidence it is handed.
    pub fn termEdges(m: *Mod, roots: []const Dispatch.TermIndex, out: *std.ArrayList(Edges.Edge)) Allocator.Error!void {
        const dt = m.in.dispatch orelse return;
        try Edges.termsEdges(out, m.walk_arena.allocator(), dt, roots, true);
    }

    /// For each derived method of a nominal type that this module emits:
    /// what the methods it calls, at any depth, can do (`edgeEffect`). A
    /// row's evidence parameters are judged where it is used.
    fn derivedFacts(m: *Mod) Allocator.Error![]const Contract.DerivedFact {
        const dt = m.in.dispatch orelse return &.{};
        var out: std.ArrayList(Contract.DerivedFact) = .empty;
        var edges: std.ArrayList(Edges.Edge) = .empty;
        defer edges.deinit(m.walk_arena.allocator());
        for (dt.derived) |row| {
            const t = switch (row.shape) {
                .nominal => |id| id,
                .record, .tuple, .unit => continue,
            };
            edges.clearRetainingCapacity();
            try m.termEdges(dt.argsAt(row.body), &edges);
            var x: Contract.Effect = .{};
            for (edges.items) |e| x = x.join(try m.edgeEffect(e));
            try out.append(m.arena, .{ .type = @backingInt(t), .kind = @backingInt(row.kind), .effect = x });
        }
        return out.items;
    }

    // ---- the signature of a declaration ------------------------------------------

    const Sig = struct { params: []PlaceId, result: PlaceId, vars: []const Var, fnt: ?TypeStore.Structure.Func };

    fn sigOf(m: *Mod, di: u32) Allocator.Error!?Sig {
        const scheme: Var.Optional = if (di < m.in.decl_scheme.len) m.in.decl_scheme[di] else .none;
        const ft = m.fnType(scheme) orelse return null;
        const vars = m.in.store.vars(ft.params);
        const params = try m.walk_arena.allocator().alloc(PlaceId, vars.len);
        for (params, vars) |*p, v| p.* = try m.placeOf(v.toOptional());
        return .{ .params = params, .result = try m.placeOf(ft.result.toOptional()), .vars = vars, .fnt = ft };
    }

    /// The contract with no flag and no source: where a group's rounds start.
    fn bottom(m: *Mod, di: u32) Allocator.Error!?*const Contract.Contract {
        const d = m.bir.decls[di];
        const sig = (try m.sigOf(di)) orelse return null;
        if (sig.params.len != d.params) return null;
        const tys = try m.walk_arena.allocator().alloc(Var.Optional, sig.vars.len);
        for (tys, sig.vars) |*t, v| t.* = v.toOptional();
        return m.bottomContract(sig.params, tys, sig.result);
    }

    /// `emptyContract`, and for each parameter of a function type the
    /// contract of a function that the body does nothing with. A parameter
    /// with no function contract is one that the checker does not follow: a
    /// caller hands it a function as to the default. So the rounds of a
    /// group, whose contracts only grow, must not start from that.
    pub fn bottomContract(m: *Mod, params: []const PlaceId, tys: []const Var.Optional, result: PlaceId) Allocator.Error!*Contract.Contract {
        const c = try m.emptyContract(params, result);
        const fns = @constCast(c.fns);
        for (fns, tys) |*f, ty| f.* = try m.bottomFn(ty);
        return c;
    }

    /// The contract of a function parameter of type `ty` that its owner does nothing with; null when `ty` is no function type.
    fn bottomFn(m: *Mod, ty: Var.Optional) Allocator.Error!?*const Contract.Fn {
        const ft = m.fnType(ty) orelse return null;
        const pvars = m.in.store.vars(ft.params);
        const arity: u32 = @intCast(pvars.len);
        const layouts = try m.arena.alloc(u32, arity + 1);
        const off = try m.arena.alloc(u32, arity + 1);
        var total: u32 = 0;
        for (pvars, 0..) |pv, k| {
            layouts[k] = try m.loc.layoutOf(try m.placeOf(pv.toOptional()));
            off[k] = total;
            total += @intCast(m.loc.layouts.items[layouts[k]].len);
        }
        off[arity] = total;
        layouts[arity] = try m.loc.layoutOf(try m.placeOf(ft.result.toOptional()));
        const supply = try m.arena.alloc([]const Src, total);
        @memset(supply, &.{});
        const free = try m.arena.alloc(bool, total);
        @memset(free, true);
        const fnc = try m.arena.create(Contract.Fn);
        fnc.* = .{ .arity = arity, .layouts = layouts, .off = off, .supply = supply, .free = free };
        return fnc;
    }

    pub fn emptyContract(m: *Mod, params: []const PlaceId, result: PlaceId) Allocator.Error!*Contract.Contract {
        const arity: u32 = @intCast(params.len);
        const layouts = try m.arena.alloc(u32, arity + 1);
        const off = try m.arena.alloc(u32, arity + 1);
        var total: u32 = 0;
        for (params, 0..) |p, k| {
            layouts[k] = try m.loc.layoutOf(p);
            off[k] = total;
            total += @intCast(m.loc.layouts.items[layouts[k]].len);
        }
        off[arity] = total;
        layouts[arity] = try m.loc.layoutOf(result);
        const flags = try m.arena.alloc(u8, total);
        @memset(flags, 0);
        const res = try m.arena.alloc([]const Src, m.loc.layouts.items[layouts[arity]].len);
        @memset(res, &.{});
        const fns = try m.arena.alloc(?*const Contract.Fn, arity);
        @memset(fns, null);
        const c = try m.arena.create(Contract.Contract);
        c.* = .{ .arity = arity, .layouts = layouts, .off = off, .flags = flags, .res = res, .fns = fns };
        return c;
    }

    // ---- worded rows (ownership-v2.md §2.13.6) --------------------------------------

    fn has(words: u32, w: W) bool {
        return words & w.bit() != 0;
    }

    fn wordedContract(m: *Mod, di: u32) Allocator.Error!?*const Contract.Contract {
        const d = m.bir.decls[di];
        const sig = (try m.sigOf(di)) orelse return null;
        const arity: u32 = @intCast(sig.params.len);
        const c = try m.emptyContract(sig.params, sig.result);
        const flags = @constCast(c.flags);
        const fns = @constCast(c.fns);
        const rl = c.layouts[arity];
        const res_es = m.loc.layoutEntries(rl);
        const gpa = m.gpa;
        var res = try gpa.alloc(std.ArrayList(Src), res_es.len);
        defer {
            for (res) |*r| r.deinit(gpa);
            gpa.free(res);
        }
        for (res) |*r| r.* = .empty;
        var pw = try gpa.alloc(u32, arity);
        defer gpa.free(pw);
        @memset(pw, 0);
        var rw: u32 = 0;
        for (m.bir.ownSlotsV2(d)) |s| {
            if (s[0] == Bir.own_result) rw = s[1] else if (s[0] < arity) pw[s[0]] = s[1];
        }
        if (arity != 0 and has(pw[0], .entry)) {
            // An `entry` without the state protocol is no word: its record
            // goes to code that the checker does not see, and a function of
            // it that writes is refused where the record is made
            // (ownership-v2.md §2.13.4 item 4; the shape test is v2's).
            const names: Prepass.EntryNames = if (m.in.interner) |i| .{ .update = i.find("update"), .settle = i.find("settle") } else .{ .update = null, .settle = null };
            if (Prepass.entryProtocol(m.bir, d, 0, names)) c.entry = true else pw[0] = 0;
        }
        const rself = try m.selfLoc(sig.result);
        const relem = try m.loc.proj(sig.result, Step.elem);
        var described = false;
        for (0..arity) |j| {
            const w = pw[j];
            const pl = c.layouts[j];
            const pes = m.loc.layoutEntries(pl);
            const pself = try m.selfLoc(sig.params[j]);
            const is_fn = m.fnType(sig.vars[j].toOptional()) != null;
            if (is_fn) {
                for (flags[c.off[j]..c.off[j + 1]]) |*x| x.* |= Contract.flag_r;
                fns[j] = try m.wordedFn(sig, c, @intCast(j), w, res);
                if (has(w, .returned) or has(w, .stored) or has(w, .aliased)) described = true;
                if (has(w, .escaped) or has(w, .aliased)) for (flags[c.off[j]..c.off[j + 1]]) |*x| {
                    x.* |= Contract.flag_e;
                };
                continue;
            }
            // A parameter with no word is read by code that the checker does not see.
            const unknown = w == 0 or has(w, .unknown);
            // What goes into a cell is behind it from then on: it escapes.
            const into_cell = has(w, .cellstored) or has(rw, .cellnew);
            for (pes, 0..) |pe, e| {
                const fl = &flags[c.off[j] + e];
                if (!has(w, .unused)) fl.* |= Contract.flag_r;
                if (has(w, .consumed) and !into_cell) fl.* |= Contract.flag_w;
                if (has(w, .written) and pe.loc == pself) fl.* |= Contract.flag_w;
                // A cell's handle is never `own`: a write of the cell asks nothing of the caller.
                if (has(w, .escaped) or into_cell or unknown) fl.* |= Contract.flag_e;
                const src: Src = .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) };
                if (has(w, .aliased) or unknown) {
                    described = true;
                    c.nonlinear = true;
                    for (res) |*r| try r.append(gpa, src);
                }
                if (has(w, .returned)) {
                    described = true;
                    var found = false;
                    for (res_es, 0..) |re, ri| if (re.loc == pe.loc) {
                        found = true;
                        try res[ri].append(gpa, src);
                    };
                    if (!found) for (res) |*r| try r.append(gpa, src);
                }
                if (has(w, .stored)) {
                    described = true;
                    try m.intoElems(res, sig.result, relem, pe.loc, src);
                }
            }
        }
        // The result's own words. `fresh` says that each location of the
        // result holds new cells: one allocation site for each location, so a
        // builder's storage and its elements are two cells, not one. A row
        // that makes one new list (`copyof` and its kin) has one site, `0`.
        if (has(rw, .fresh) or has(rw, .exclusive) or has(rw, .cellnew) or has(rw, .cellempty)) {
            described = true;
            for (res, 0..) |*r, ri| try r.append(gpa, Src.fresh(@intCast(ri), false));
        }
        if (has(rw, .copyof) or has(rw, .concatenated) or has(rw, .prepended)) {
            described = true;
            for (res_es, 0..) |re, ri| if (re.loc == rself) try res[ri].append(gpa, Src.fresh(0, false));
            if (arity > 0 and !has(rw, .prepended)) try m.elemsToElems(res, sig, c, 0);
            if (arity > 1 and !has(rw, .copyof)) try m.elemsToElems(res, sig, c, 1);
            if (has(rw, .concatenated) and arity > 0) try m.selfToSelf(res, sig, c, 0);
            if (has(rw, .prepended) and arity > 1) try m.selfToSelf(res, sig, c, 1);
        }
        if (has(rw, .builderdone) and arity > 0) {
            described = true;
            for (m.loc.layoutEntries(c.layouts[0]), 0..) |pe, e| for (res_es, 0..) |re, ri| if (re.loc == pe.loc) {
                try res[ri].append(gpa, .{ .kind = .param, .a = 0, .e = @intCast(e) });
            };
        }
        if ((has(rw, .elementof) or has(rw, .taken)) and arity > 0) {
            described = true;
            if (has(rw, .taken)) c.taken = true;
            if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
                const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
                for (child, 0..) |ce, k| {
                    if (pr.up[k] == none) continue;
                    const src: Src = .{ .kind = .param, .a = 0, .e = @intCast(pr.up[k]) };
                    var found = false;
                    for (res_es, 0..) |re, ri| if (re.loc == ce.loc) {
                        found = true;
                        try res[ri].append(gpa, src);
                    };
                    if (!found) for (res) |*r| try r.append(gpa, src);
                }
            } else try m.undescribed(c, res);
        }
        // A result that comes from behind a cell or from JavaScript, or
        // that no word describes: the pessimistic row (`undescribed`).
        if (has(rw, .lent) or has(rw, .lentoptional) or has(rw, .cellread) or has(rw, .unknown) or !described) try m.undescribed(c, res);
        const out = @constCast(c.res);
        for (out, res) |*o, r| o.* = try Contract.normal(m.arena, r.items);
        return c;
    }

    /// The result of a worded row that the words do not describe: it can be
    /// a cell outside every frame (JavaScript's, a cell's contents), so no
    /// frame may write it, and it can hold every cell of every parameter, at
    /// any place (kernel §6.10: a missing fact is the pessimistic one).
    fn undescribed(m: *Mod, c: *Contract.Contract, res: []std.ArrayList(Src)) Allocator.Error!void {
        c.nonlinear = true;
        for (res) |*r| {
            try r.append(m.gpa, Src.outside);
            for (0..c.arity) |j| for (0..m.loc.layoutEntries(c.layouts[j]).len) |e| try r.append(m.gpa, .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) });
        }
    }

    fn intoElems(m: *Mod, res: []std.ArrayList(Src), result: PlaceId, relem: ?*const Loc.Proj, loc: u32, src: Src) Allocator.Error!void {
        const pr = relem orelse {
            for (res) |*r| try r.append(m.gpa, src);
            return;
        };
        const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
        var found = false;
        for (child, 0..) |ce, k| if (ce.loc == loc and pr.up[k] != none) {
            found = true;
            try res[pr.up[k]].append(m.gpa, src);
        };
        _ = result;
        if (!found) for (pr.up) |u| if (u != none) try res[u].append(m.gpa, src);
    }

    /// The result's elements hold the elements of parameter `j`.
    fn elemsToElems(m: *Mod, res: []std.ArrayList(Src), sig: Sig, c: *const Contract.Contract, j: u32) Allocator.Error!void {
        const pself = try m.selfLoc(sig.params[j]);
        const rself = try m.selfLoc(sig.result);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| {
            if (pe.loc == pself) continue;
            const src: Src = .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) };
            var found = false;
            for (res_es, 0..) |re, ri| if (re.loc == pe.loc and re.loc != rself) {
                found = true;
                try res[ri].append(m.gpa, src);
            };
            if (!found) for (res_es, 0..) |re, ri| if (re.loc != rself) try res[ri].append(m.gpa, src);
        }
    }

    /// The result's storage can be parameter `j`'s.
    fn selfToSelf(m: *Mod, res: []std.ArrayList(Src), sig: Sig, c: *const Contract.Contract, j: u32) Allocator.Error!void {
        const pself = try m.selfLoc(sig.params[j]);
        const rself = try m.selfLoc(sig.result);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| if (pe.loc == pself) {
            for (res_es, 0..) |re, ri| if (re.loc == rself) try res[ri].append(m.gpa, .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) });
        };
    }

    /// The words of a function parameter: `taken` hands it the elements of
    /// parameter 0, `stored` puts its answer among the result's elements,
    /// `returned` makes its answer the result.
    fn wordedFn(m: *Mod, sig: Sig, c: *const Contract.Contract, j: u32, w: u32, res: []std.ArrayList(Src)) Allocator.Error!?*const Contract.Fn {
        const ft = m.fnType(sig.vars[j].toOptional()) orelse return null;
        const pvars = m.in.store.vars(ft.params);
        const arity: u32 = @intCast(pvars.len);
        const layouts = try m.arena.alloc(u32, arity + 1);
        const off = try m.arena.alloc(u32, arity + 1);
        var total: u32 = 0;
        for (pvars, 0..) |pv, k| {
            layouts[k] = try m.loc.layoutOf(try m.placeOf(pv.toOptional()));
            off[k] = total;
            total += @intCast(m.loc.layouts.items[layouts[k]].len);
        }
        off[arity] = total;
        const rplace = try m.placeOf(ft.result.toOptional());
        layouts[arity] = try m.loc.layoutOf(rplace);
        const supply = try m.arena.alloc([]const Src, total);
        const free = try m.arena.alloc(bool, total);
        const taken = has(w, .taken);
        @memset(free, taken);
        // What the words do not say the row hands the function, the
        // pessimistic row does: every cell of every parameter, not `free`
        // (kernel §6.10). `taken` names the elements below.
        var every: std.ArrayList(Src) = .empty;
        defer every.deinit(m.gpa);
        for (0..c.arity) |pj| for (0..m.loc.layoutEntries(c.layouts[pj]).len) |pe| try every.append(m.gpa, .{ .kind = .param, .a = @intCast(pj), .e = @intCast(pe) });
        @memset(supply, try Contract.normal(m.arena, every.items));
        if (taken and arity > 0 and sig.params.len > 0) {
            // The function is handed one element of parameter 0, taken out of the list.
            if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
                const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
                for (m.loc.layoutEntries(layouts[0]), 0..) |fe, e| {
                    var srcs: std.ArrayList(Src) = .empty;
                    defer srcs.deinit(m.gpa);
                    for (child, 0..) |ce, k| if (ce.loc == fe.loc and pr.up[k] != none) try srcs.append(m.gpa, .{ .kind = .param, .a = 0, .e = @intCast(pr.up[k]) });
                    if (srcs.items.len != 0) supply[off[0] + e] = try Contract.normal(m.arena, srcs.items);
                    for (srcs.items) |s| @constCast(c.flags)[c.off[0] + s.e] |= Contract.flag_s;
                }
            }
        }
        // Its answer.
        const ans = m.loc.layoutEntries(layouts[arity]);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        const relem = try m.loc.proj(sig.result, Step.elem);
        for (ans, 0..) |ae, e| {
            const src: Src = .{ .kind = .answer, .a = @intCast(j), .e = @intCast(e) };
            if (has(w, .returned)) {
                var found = false;
                for (res_es, 0..) |re, ri| if (re.loc == ae.loc) {
                    found = true;
                    try res[ri].append(m.gpa, src);
                };
                if (!found) for (res) |*r| try r.append(m.gpa, src);
            }
            if (has(w, .stored)) try m.intoElems(res, sig.result, relem, ae.loc, src);
            if (has(w, .aliased)) for (res) |*r| try r.append(m.gpa, src);
        }
        const fnc = try m.arena.create(Contract.Fn);
        fnc.* = .{
            .arity = arity,
            .layouts = layouts,
            .off = off,
            .supply = supply,
            .free = free,
            .called = true,
            // A cell's callback runs once, now; the cell keeps what it answers.
            .lost = !(taken or has(w, .once) or has(w, .many) or has(w, .cellupdate) or has(w, .cellmodify)),
            .ans_escapes = has(w, .cellupdate) or has(w, .cellmodify),
        };
        return fnc;
    }

    // ---- one declaration --------------------------------------------------------------

    /// Walk declaration `di` to its contract, or null: it has no body, no
    /// signature, or its walk gave up (kernel §3.3; then its lines are all
    /// refused, and `limits` says so).
    fn walkDecl(m: *Mod, di: u32) Allocator.Error!?*const Contract.Contract {
        const d = m.bir.decls[di];
        const body = d.body.unwrap() orelse return null;
        @memset(m.lframe[d.locals_start..d.locals_end], 0);
        @memset(m.lv[d.locals_start..d.locals_end], Frame.v_unbound);
        @memset(m.lbinder[d.locals_start..d.locals_end], 0);
        var f = try Frame.init(m, null, di, false, none);
        const params = m.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Inst.Index);
        const sig = try m.sigOf(di);
        f.own_params = @intCast(params.len);
        for (params, 0..) |p, k| {
            const place = if (sig) |s| (if (k < s.params.len) s.params[k] else m.var_place) else m.var_place;
            const ty: Var.Optional = if (sig) |s| (if (k < s.vars.len) s.vars[k].toOptional() else .none) else .none;
            try f.addParam(place, p.int(), ty);
        }
        const result_place = if (sig) |s| (if (params.len == s.params.len) s.result else try m.placeOfInst(body.int())) else try m.placeOfInst(body.int());
        try f.walkBody(body.int());
        const c = try f.finish(result_place);
        if (f.failed) {
            try m.limits.append(m.arena, try std.fmt.allocPrint(m.arena, "limit {s}: the walk gave up", .{m.names.declName(m.in.module, di)}));
            m.failed_decl[di] = true;
            return null;
        }
        if (params.len == 0) {
            // A function value declared with no parameter: a call of it runs the lambda its body is.
            if (m.tags[body.int()] == .lambda) return m.code_contract[body.int()];
            // A constant: its contract says which locations it holds a cell at.
            return c;
        }
        return c;
    }

    fn solveGroup(m: *Mod, members: []const u32, recursive: bool) Allocator.Error!void {
        for (members) |di| {
            m.state[di] = .working;
            m.contracts[di] = if (recursive) try m.bottom(di) else null;
            if (m.contracts[di]) |c| try m.drafts.put(m.gpa, @intFromPtr(c), {});
        }
        defer m.drafts.clearRetainingCapacity();
        const mark = m.lines.items.len;
        const lmark = m.limits.items.len;
        var rounds: u32 = 0;
        while (true) : (rounds += 1) {
            var changed = false;
            m.lines.shrinkRetainingCapacity(mark);
            m.limits.shrinkRetainingCapacity(lmark);
            for (members) |di| m.failed_decl[di] = false;
            for (members) |di| {
                const got = try m.walkDecl(di);
                _ = m.walk_arena.reset(.retain_capacity);
                const old = m.contracts[di];
                // A walk that gave up has no contract, whatever the rounds
                // before found: a callee with no contract is unknown code.
                const next: ?*const Contract.Contract = if (got) |g| (if (old) |o| try Contract.join(m.arena, o, g) else g) else null;
                if ((old == null) != (next == null) or (old != null and !Contract.eql(old.?, next.?))) changed = true;
                m.contracts[di] = next;
                if (recursive) if (next) |c| try m.drafts.put(m.gpa, @intFromPtr(c), {});
            }
            if (!recursive or !changed) break;
            if (rounds > 64) {
                try m.limits.append(m.arena, try std.fmt.allocPrint(m.arena, "limit {s}: the group did not settle", .{m.names.declName(m.in.module, members[0])}));
                break;
            }
        }
        for (members) |di| m.state[di] = .done;
    }

    // ---- text -----------------------------------------------------------------------------

    fn refName(m: *const Mod, t: [2]u32) Allocator.Error![]const u8 {
        if (t[0] >= m.names.module_names.len) return "?";
        return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ m.names.module_names[t[0]], m.names.declName(t[0], t[1]) });
    }

    fn localName(m: *const Mod, d: Bir.Decl, local: u32) []const u8 {
        const name = m.bir.locals[d.locals_start + local].name;
        return if (name == .none) "_" else m.symbolText(name);
    }

    fn opName(m: *Mod, f: *const Frame, inst: u32) Allocator.Error![]const u8 {
        if (inst == none) return "call";
        switch (m.tags[inst]) {
            .top, .ext_value => if (m.calleeOf(inst)) |t| return m.refName(t),
            .method_call => return if (m.methodTarget(inst)) |t| m.refName(t) else "<derived method>",
            .type_dispatch => return "<dispatched method>",
            .local => return m.localName(f.d, m.datas[inst].lhs),
            else => {},
        }
        return "call";
    }

    fn baseText(m: *Mod, f: *const Frame, inst: u32) Allocator.Error![]const u8 {
        if (inst == none) return "<value>";
        const data = m.datas[inst];
        switch (m.tags[inst]) {
            .local => return m.localName(f.d, data.lhs),
            .list => return "<literal>",
            .lambda => return "<lambda>",
            .record, .record_update => return "<record>",
            .tuple => return "<tuple>",
            .top, .ext_value => if (m.calleeOf(inst)) |t| return m.refName(t),
            .field_access => return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ try m.baseText(f, data.lhs), m.symbolText(@fromBackingInt(data.rhs)) }),
            .tuple_index => return std.fmt.allocPrint(m.arena, "{s}.{d}", .{ try m.baseText(f, data.lhs), data.rhs }),
            .call => {
                if (m.spreadOf(f.d, inst) != null) return "<construction>";
                if (m.isListAppend(inst)) return "<++>";
                switch (m.tags[data.lhs]) {
                    .ctor, .ext_ctor => return "<constructor …>",
                    .top, .ext_value => if (m.calleeOf(data.lhs)) |t| return std.fmt.allocPrint(m.arena, "<call {s}>", .{try m.refName(t)}),
                    else => {},
                }
                return "<call>";
            },
            .method_call => if (m.methodTarget(inst)) |t| return std.fmt.allocPrint(m.arena, "<call {s}>", .{try m.refName(t)}),
            else => {},
        }
        return "<expression>";
    }

    pub fn locText(m: *Mod, loc: u32) Allocator.Error![]const u8 {
        if (loc == 0) return "";
        var labels: std.ArrayList(u64) = .empty;
        defer labels.deinit(m.gpa);
        try m.loc.labels(loc, &labels, m.gpa);
        var out: std.Io.Writer.Allocating = .init(m.arena);
        for (labels.items) |lw| {
            const l: Loc.Label = @bitCast(lw);
            switch (l.kind) {
                .field => out.writer.print(".{s}", .{m.names.field(m.names.ctx, l.payload)}) catch return error.OutOfMemory,
                .index => out.writer.print(".{d}", .{l.payload}) catch return error.OutOfMemory,
                .ctor_arg => out.writer.print("#{s}.{d}", .{ m.names.ctor(m.names.ctx, l.head, l.payload >> 12), l.payload & 0xfff }) catch return error.OutOfMemory,
                .elem => out.writer.writeAll("[*]") catch return error.OutOfMemory,
                .contents => out.writer.writeAll("◆") catch return error.OutOfMemory,
                .row => out.writer.writeAll(".…") catch return error.OutOfMemory,
                .member => out.writer.print("⟨{s}⟩", .{m.names.type_name(m.names.ctx, l.head)}) catch return error.OutOfMemory,
                .env => out.writer.writeAll("◇") catch return error.OutOfMemory,
                .slot => out.writer.print("⟨{d}⟩", .{l.payload}) catch return error.OutOfMemory,
            }
        }
        return out.written();
    }

    pub fn useText(m: *Mod, f: *const Frame, point: u32) Allocator.Error![]const u8 {
        const pos = m.names.position(m.names.ctx, m.in.module, m.tokens[point]);
        return std.fmt.allocPrint(m.arena, "it is read again at {d}:{d} ({s})", .{ pos.line, pos.col, try m.baseText(f, point) });
    }

    pub fn addLine(m: *Mod, f: *const Frame, d: anytype, ground: Facts.Verdict.Accepted) Allocator.Error!void {
        const op: []const u8 = switch (d.op) {
            .construction => "construction",
            .append => "++",
            .call, .supply => if (d.kind == .send) "send" else if (d.kind == .callsite) try std.fmt.allocPrint(m.arena, "call {s}", .{try m.opName(f, d.callee_inst)}) else try m.opName(f, d.callee_inst),
        };
        const base = try std.fmt.allocPrint(m.arena, "{s}{s}", .{ try m.baseText(f, d.base_inst), try m.locText(d.loc) });
        const cause: Facts.Cause = d.refused orelse .unknown;
        try m.lines.append(m.gpa, .{
            .inst = d.point,
            .token = d.token,
            .kind = d.kind,
            .op = op,
            .base = base,
            .refused = d.refused != null,
            .accepted = ground,
            .cause = cause,
            .detail = if (d.detail.len != 0) d.detail else causeDetail(cause),
        });
    }

    fn causeDetail(c: Facts.Cause) []const u8 {
        return switch (c) {
            .unknown => "the checker has no claim on this value",
            .captured => "a function captured it",
            .call => "it is the answer of a function parameter",
            .element => "one cell can be at two positions of it",
            .disjoint => "another operand of the same operation reaches it",
            .held_operand => "an operand that waits for its consumer holds it",
            .escaped => "it escaped before the write",
            else => "",
        };
    }

    pub fn addRefusal(m: *Mod, f: *const Frame, inst: u32, cause: Facts.Cause, detail: []const u8) Allocator.Error!void {
        try m.lines.append(m.gpa, .{ .inst = inst, .token = m.tokens[inst], .kind = .callsite, .op = "value", .base = try m.baseText(f, inst), .refused = true, .cause = cause, .detail = detail });
    }

    pub fn addEntryLine(m: *Mod, f: *const Frame, inst: u32, code: anytype, model: bool, loc: u32, ok: bool) Allocator.Error!void {
        _ = f;
        const name: []const u8 = if (code.decl[0] != none) try m.refName(code.decl) else "<lambda>";
        try m.lines.append(m.gpa, .{
            .inst = inst,
            .token = m.tokens[inst],
            .kind = .entry,
            .op = try std.fmt.allocPrint(m.arena, "entry {s}", .{name}),
            .base = try std.fmt.allocPrint(m.arena, "{s}{s}", .{ if (model) "model" else "msg", try m.locText(loc) }),
            .refused = !ok,
            .accepted = .entry,
            .cause = .unknown,
            .detail = if (ok) "" else "the runtime does not hand this as the function's own",
        });
    }

    fn summaryText(m: *Mod, di: u32, c: *const Contract.Contract) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(m.arena);
        const w = &out.writer;
        w.print("summary {s}:", .{m.names.declName(m.in.module, di)}) catch return error.OutOfMemory;
        for (0..c.arity) |j| {
            for (m.loc.layoutEntries(c.layouts[j]), 0..) |e, k| {
                const fl = c.flags[c.off[j] + k];
                if (fl == 0) continue;
                w.print(" π{d}{s} {s}{s}", .{ j + 1, try m.locText(e.loc), if (fl & Contract.flag_w != 0) "W" else "", if (fl & Contract.flag_e != 0) "E" else "" }) catch return error.OutOfMemory;
            }
            if (c.fns[j]) |fnc| {
                w.print(" π{d} fn{s}{s}{s}{s}", .{ j + 1, if (fnc.called) " called" else "", if (fnc.lost) " lost" else "", if (fnc.ans_escapes) " answer-escapes" else "", if (fnc.rewrites) " rewrites" else "" }) catch return error.OutOfMemory;
                for (0..fnc.arity) |k| for (m.loc.layoutEntries(fnc.layouts[k]), 0..) |e, i| {
                    const slot = fnc.off[k] + i;
                    w.print(" ({d}{s}{s}", .{ k + 1, try m.locText(e.loc), if (fnc.free[slot]) "" else " held" }) catch return error.OutOfMemory;
                    try m.srcsText(w, fnc.supply[slot]);
                    w.writeAll(")") catch return error.OutOfMemory;
                };
            }
        }
        w.writeAll("; res") catch return error.OutOfMemory;
        for (m.loc.layoutEntries(c.layouts[c.arity]), 0..) |e, k| {
            w.print(" [{s}", .{try m.locText(e.loc)}) catch return error.OutOfMemory;
            try m.srcsText(w, c.res[k]);
            w.writeAll("]") catch return error.OutOfMemory;
        }
        return out.written();
    }

    fn srcsText(m: *Mod, w: *std.Io.Writer, srcs: []const Src) Allocator.Error!void {
        _ = m;
        for (srcs) |s| switch (s.kind) {
            .fresh => w.print(" fresh{d}{s}", .{ s.a, if (s.e != 0) "!" else "" }) catch return error.OutOfMemory,
            .outside => w.writeAll(" outside") catch return error.OutOfMemory,
            .param => w.print(" π{d}@{d}", .{ s.a + 1, s.e }) catch return error.OutOfMemory,
            .answer => w.print(" answer{d}@{d}", .{ s.a + 1, s.e }) catch return error.OutOfMemory,
            .twice => w.writeAll(" twice") catch return error.OutOfMemory,
        };
    }
};

/// Check module `in`. The result lives in `arena`, the published contracts in `gpa`.
pub fn checkModule(gpa: Allocator, arena: Allocator, in: *const Groups.Input, shared: *const Shared, names: Names, options: Options) Allocator.Error!Result {
    const bir = in.bir;
    var m: Mod = .{
        .gpa = gpa,
        .arena = arena,
        .walk_arena = .init(gpa),
        .in = in,
        .bir = bir,
        .tags = bir.insts.items(.tag),
        .datas = bir.insts.items(.data),
        .tokens = bir.insts.items(.main_token),
        .names = names,
        .shared = shared,
        .markup_type = options.markup_type,
    };
    defer m.walk_arena.deinit();
    defer m.places.deinit(gpa);
    defer m.account.deinit(gpa);
    m.account.walk = .growth;
    m.adapter = .{ .in = in, .gpa = gpa, .places = &m.places, .account = &m.account };
    defer m.adapter.deinit();
    m.loc = try Loc.Table.init(gpa, arena, &m.places);
    defer m.loc.deinit();
    defer m.lines.deinit(gpa);
    defer m.spread_root.deinit(gpa);
    m.var_place = m.adapter.placeOfVar(.none) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("ownership v3: the place of a type variable"),
    };
    var prepass_arena: std.heap.ArenaAllocator = .init(gpa);
    defer prepass_arena.deinit();
    m.prepass = try Prepass.run(gpa, prepass_arena.allocator(), .{ .bir = bir, .dispatch = in.dispatch });

    const nd = bir.decls.len;
    m.lv = try gpa.alloc(Frame.Val, bir.locals.len);
    defer gpa.free(m.lv);
    m.lframe = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lframe);
    @memset(m.lframe, 0);
    m.lbinder = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lbinder);
    @memset(m.lbinder, 0);
    m.lcode = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lcode);
    @memset(m.lcode, Loc.none);
    m.lgroup = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lgroup);
    @memset(m.lgroup, Loc.none);
    m.lindex = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lindex);
    @memset(m.lindex, Loc.none);
    defer m.groups.deinit(gpa);
    m.let_seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, bir.insts.len);
    defer m.let_seen.deinit(gpa);
    m.recalled = try gpa.alloc(bool, bir.insts.len);
    defer gpa.free(m.recalled);
    @memset(m.recalled, false);
    m.code_caps = try gpa.alloc([]const u32, bir.insts.len);
    defer gpa.free(m.code_caps);
    @memset(m.code_caps, &.{});
    m.code_contract = try gpa.alloc(?*const Contract.Contract, bir.insts.len);
    defer gpa.free(m.code_contract);
    @memset(m.code_contract, null);
    m.contracts = try gpa.alloc(?*const Contract.Contract, nd);
    defer gpa.free(m.contracts);
    @memset(m.contracts, null);
    m.failed_decl = try gpa.alloc(bool, nd);
    defer gpa.free(m.failed_decl);
    @memset(m.failed_decl, false);
    m.state = try gpa.alloc(State, nd);
    defer gpa.free(m.state);
    @memset(m.state, .todo);
    m.worded_done = try gpa.alloc(bool, nd);
    defer gpa.free(m.worded_done);
    @memset(m.worded_done, false);
    m.readers = try gpa.alloc(?Contract.Reader, in.birs.len);
    defer gpa.free(m.readers);
    defer m.drafts.deinit(gpa);
    defer m.sites.deinit(gpa);
    @memset(m.readers, null);
    m.spread_root = try std.DynamicBitSetUnmanaged.initEmpty(gpa, bir.insts.len);
    for (bir.decls) |d| for (bir.spreads(d)) |s| if (s.root < bir.insts.len) m.spread_root.set(s.root);

    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    for (0..m.prepass.starts.len - 1) |gi| {
        members.clearRetainingCapacity();
        for (m.prepass.order[m.prepass.starts[gi]..m.prepass.starts[gi + 1]]) |di| {
            const d = bir.decls[di];
            if (d.kind != .value or d.body == .none or bir.ownSlotsV2(d).len != 0) continue;
            try members.append(gpa, di);
        }
        if (members.items.len == 0) continue;
        std.mem.sort(u32, members.items, {}, std.sort.asc(u32));
        try m.solveGroup(members.items, m.prepass.recursive[gi]);
    }
    // A worded declaration's contract is its words. Its body is walked for
    // its own verdicts only, when every contract of the module is known.
    for (bir.decls, 0..) |d, di| {
        if (!d.kind.isValue() or bir.ownSlotsV2(d).len == 0) continue;
        _ = try m.declContract(.{ in.module, @intCast(di) });
        if (d.kind != .value or d.body == .none) continue;
        _ = try m.walkDecl(@intCast(di));
        // Its contract is its words, a trusted row, whatever its walk found.
        m.failed_decl[di] = false;
        _ = m.walk_arena.reset(.retain_capacity);
    }
    var summaries: std.ArrayList([]const u8) = .empty;
    if (options.summaries) for (m.contracts, 0..) |c, di| if (c) |x| try summaries.append(arena, try m.summaryText(@intCast(di), x));
    // A walk that gave up publishes nothing (kernel §3.3).
    if (std.debug.runtime_safety) for (m.contracts, m.failed_decl) |c, failed| std.debug.assert(!(failed and c != null));
    // A type past the layout limit (kernel §8, `Loc.max_layout_entries`): the
    // walk read its places as one summary location, so the module authorises
    // no write (`limits`) and publishes no contract. An importer reads each
    // of its declarations as unknown code.
    if (m.loc.over.items.len != 0) {
        try m.limits.append(m.arena, try std.fmt.allocPrint(m.arena, "limit {s}: a type has more than {d} locations (a location for each path of labels through it), so the checker judges no write of the module", .{ m.names.module_names[in.module], Loc.max_layout_entries }));
        @memset(m.contracts, null);
    }
    // A module past a limit publishes no contract, and so no derived fact.
    const derived = if (m.loc.over.items.len != 0) &.{} else try m.derivedFacts();
    const published = try Contract.publish(gpa, &m.loc, m.contracts, derived);
    return .{ .lines = try arena.dupe(Line, m.lines.items), .published = published, .limits = m.limits.items, .summaries = summaries.items };
}
