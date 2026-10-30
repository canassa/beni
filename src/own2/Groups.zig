//! L10: the module (`docs/design/ownership-v2.md` §2.1, §5, §8 S3a): the
//! source and signature adapters, and the walk of every declaration.
//!
//! **The place source** (§2.1). `Place` reads a type through `Place.Source`;
//! this file is that source over the checker's tables, and with `Place` the
//! one part of `own2/` that reads a type's structure (§5's fence). A node of
//! the source graph is a canonical id, structural: a record by its fields'
//! text ranks and children, a tuple by its children, a nominal type by its
//! `TypeId` and its argument ids — the memo on `(head, argument places)` of
//! §2.1, so a recursive type folds at its head and another instantiation is
//! another place. A nominal type's constructor payloads are its BIR
//! constructor templates read under an environment of argument ids (never
//! fresh store variables), expanded only when `Place` visits the node; a
//! nominal type met again inside its own payload with other arguments (a
//! non-regular type) folds onto its head with every argument a `var` place,
//! which holds anything. `sequence` metadata makes a list (`[*]` its
//! argument), `cell` a cell (`◆`); `Int`, `Float`, `Char`, `String` and a
//! `crossing foreign type` cross; any other foreign type is opaque. A store
//! variable met again while it is being read (a cyclic type with no name,
//! #955) is one node, its knot kept.
//!
//! **The signature adapter** (§5): a worded declaration's words
//! (`Bir.ownSlotsV2`) over the places of the call's own arguments and
//! result — the instantiation at that call — make its class
//! (`Rows.fromWords`).
//!
//! Obligations kept here: none of §2.14's directly; the adapter's places
//! are what O6's "`⟲` covers every level" folds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Calls = @import("Calls.zig");
const Rows = @import("Rows.zig");
const Prepass = @import("Prepass.zig");
const Transfer = @import("Transfer.zig");
const Walk = @import("Walk.zig");
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Interface = @import("../resolve/Interface.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const stamped = @import("../stamped.zig");
const Ast = @import("../parse/Ast.zig");

pub const PlaceId = Ids.PlaceId;
pub const ClassId = Ids.ClassId;
pub const Error = Ids.ChargeError;
const Var = TypeStore.Var;
const Step = Place.Step;
const none = Ids.none_int;

pub const Input = struct {
    gpa: Allocator,
    module: u32,
    bir: *const Bir,
    store: *TypeStore,
    inst_type: []const Var.Optional,
    local_type: []const Var.Optional,
    decl_scheme: []const Var.Optional,
    types: *const Types,
    /// Per module: its BIR, for constructor templates and callees' words.
    birs: []const *const Bir,
    provenance: []const Interface.Provenance,
    dispatch: ?*const Dispatch,
    /// Per global symbol, its rank in text order (§3.8).
    ranks: []const u32,
    /// Per module, whether it is in the core package; its comparisons are
    /// trusted to compose their evidence (§2.13.13).
    core: []const bool = &.{},
    /// Symbol text, to name a type's `eq`/`compare`.
    interner: ?*const InternPool.Global = null,
    /// The imports' published classes (§2.11, §3.6; S3b slice 3), or none.
    imports: ?Imports = null,

    pub fn isCore(in: *const Input, m: u32) bool {
        return m < in.core.len and in.core[m];
    }
};

/// How a module reads another's classes (§3.6): module `m`'s block decoded
/// into `mod`'s tables, per declaration of `m` its class an importer may
/// apply or `.none`; null when `m` publishes no block, or one that does not
/// decode (R-5.7.4: an unknown summary). Only a module `mod` imports is read.
pub const Imports = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, mod: *Module, m: u32) Error!?[]ClassId,
};

// ---------------------------------------------------------------------------
// The place source
// ---------------------------------------------------------------------------

const Kind = enum(u8) { structural, nominal, cyclic };

const Node = struct {
    kind: Kind,
    place_kind: Place.Kind,
    head: u32,
    /// `structural`, `cyclic`: a run of `kids`. `nominal`: the argument list.
    a: u32,
    b: u32,
    /// `nominal`: the nominal node whose payloads first named it, `none` for
    /// one read off a store variable: the chain a non-regular type folds on.
    origin: u32 = none,
};

const Kid = struct { step: Step, id: u32 };

pub const Adapter = struct {
    in: *const Input,
    gpa: Allocator,
    places: *Place.Table,
    account: *Ids.Account,
    nodes: std.ArrayList(Node) = .empty,
    kids: std.ArrayList(Kid) = .empty,
    /// Structural and nominal keys → id; argument lists as cons cells.
    keys: Ids.FixedDict(3) = .{},
    lists: Ids.FixedDict(2) = .{},
    list_cells: std.ArrayList([2]u32) = .empty,
    /// Store root → id, and roots being read (a cycle's knot).
    by_var: stamped.Column(u32, u32) = .{},
    open: stamped.Column(u32, u32) = .{},
    var_id: u32 = none,
    cross_id: u32 = none,
    closure_id: u32 = none,

    pub fn deinit(a: *Adapter) void {
        a.nodes.deinit(a.gpa);
        a.kids.deinit(a.gpa);
        a.keys.deinit(a.gpa);
        a.lists.deinit(a.gpa);
        a.list_cells.deinit(a.gpa);
        a.by_var.deinit(a.gpa);
        a.open.deinit(a.gpa);
    }

    fn add(a: *Adapter, n: Node) Allocator.Error!u32 {
        const id: u32 = @intCast(a.nodes.items.len);
        try a.nodes.append(a.gpa, n);
        return id;
    }

    fn leaf(a: *Adapter, slot: *u32, k: Place.Kind) Allocator.Error!u32 {
        // `⊤`'s head is no type's, so it is told from a crossing type's.
        if (slot.* == none) slot.* = try a.add(.{ .kind = .structural, .place_kind = k, .head = if (k == .cross) none else 0, .a = 0, .b = 0 });
        return slot.*;
    }

    /// The cons list `(head, tail)`, interned.
    fn cons(a: *Adapter, head: u32, tail: u32) Allocator.Error!u32 {
        const got = try a.lists.getOrPut(a.gpa, .{ head, tail });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(a.list_cells.items.len);
            try a.list_cells.append(a.gpa, .{ head, tail });
        }
        return got.value_ptr.*;
    }

    fn listOf(a: *Adapter, ids: []const u32) Allocator.Error!u32 {
        var l: u32 = none;
        var i = ids.len;
        while (i > 0) {
            i -= 1;
            l = try a.cons(ids[i], l);
        }
        return l;
    }

    fn listAt(a: *const Adapter, list: u32, k: u32) u32 {
        var l = list;
        var i = k;
        while (l != none) : (i -= 1) {
            if (i == 0) return a.list_cells.items[l][0];
            l = a.list_cells.items[l][1];
        }
        return none;
    }

    /// A structural node by its kind and children, interned.
    fn structural(a: *Adapter, k: Place.Kind, head: u32, kids: []const Kid) Allocator.Error!u32 {
        // The key: the children as a cons list of (step word, id) pairs.
        var l: u32 = none;
        var i = kids.len;
        while (i > 0) {
            i -= 1;
            l = try a.cons(try a.cons(kids[i].step.word(), kids[i].id), l);
        }
        const got = try a.keys.getOrPut(a.gpa, .{ @backingInt(k), head, l });
        if (got.found_existing) return got.value_ptr.*;
        const start: u32 = @intCast(a.kids.items.len);
        try a.kids.appendSlice(a.gpa, kids);
        got.value_ptr.* = try a.add(.{ .kind = .structural, .place_kind = k, .head = head, .a = start, .b = @intCast(kids.len) });
        return got.value_ptr.*;
    }

    fn nominal(a: *Adapter, t: Types.TypeId, args: []const u32, origin: u32) Allocator.Error!u32 {
        const list = try a.listOf(args);
        const got = try a.keys.getOrPut(a.gpa, .{ 0x100, t.int(), list });
        if (got.found_existing) return got.value_ptr.*;
        got.value_ptr.* = try a.add(.{ .kind = .nominal, .place_kind = .ctor, .head = t.int(), .a = list, .b = @intCast(args.len), .origin = origin });
        return got.value_ptr.*;
    }

    /// A symbol's text rank (§3.8). Every symbol a body or a type names is
    /// interned by parsing and lowering, before `Enforce.inputs` ranks them
    /// all, and the checker interns none; a session id must never stand in
    /// for a rank (it would reach published bytes), so a miss is a defect.
    fn rank(a: *const Adapter, s: InternPool.Symbol) u32 {
        const i = @backingInt(s);
        if (i >= a.in.ranks.len) @panic("ownership v2: a symbol interned after the ranks were taken");
        return a.in.ranks[i];
    }

    // ---- store variables -----------------------------------------------------

    /// The id of store variable `v`: post-order over its structure on an
    /// explicit stack, each root once.
    pub fn ofVar(a: *Adapter, v: Var) Error!u32 {
        const store = a.in.store;
        const root, _ = store.resolved(v);
        if (a.by_var.get(root.int())) |id| return id;
        const Frame = struct { v: Var, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(a.gpa);
        try stack.append(a.gpa, .{ .v = root, .expanded = false });
        var kids: std.ArrayList(Kid) = .empty;
        defer kids.deinit(a.gpa);
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(a.gpa);
        while (stack.pop()) |f| {
            const r, const c = store.resolved(f.v);
            if (a.by_var.contains(r.int())) continue;
            if (!f.expanded) {
                if (a.open.contains(r.int())) continue;
                try a.open.put(a.gpa, r.int(), none);
                try stack.append(a.gpa, .{ .v = r, .expanded = true });
                for (children(store, c)) |ch| {
                    const cr, _ = store.resolved(ch);
                    if (!a.by_var.contains(cr.int())) try stack.append(a.gpa, .{ .v = cr, .expanded = false });
                }
                continue;
            }
            const id = try a.close(r, c, &kids, &ids);
            const knot = a.open.get(r.int()).?;
            a.open.remove(r.int());
            if (knot != none) {
                // A cyclic type with no name: the knot is this node.
                a.nodes.items[knot] = a.nodes.items[id];
                try a.by_var.put(a.gpa, r.int(), knot);
            } else try a.by_var.put(a.gpa, r.int(), id);
        }
        return a.by_var.get(root.int()).?;
    }

    fn children(store: *TypeStore, c: TypeStore.Content) []const Var {
        return switch (c) {
            .structure => |s| switch (s) {
                .tuple => |r| store.vars(r),
                .app => |ap| store.vars(ap.args),
                else => &.{},
            },
            else => &.{},
        };
    }

    /// The id of a child read while its parent closes: its own, or the knot
    /// of a variable still open (a cycle).
    fn childId(a: *Adapter, v: Var) Error!u32 {
        const r, _ = a.in.store.resolved(v);
        if (a.by_var.get(r.int())) |id| return id;
        if (a.open.getPtr(r.int())) |knot| {
            if (knot.* == none) knot.* = try a.add(.{ .kind = .cyclic, .place_kind = .@"var", .head = 0, .a = 0, .b = 0 });
            return knot.*;
        }
        // A record's field types are read here, on demand.
        return a.ofVar(v);
    }

    fn close(a: *Adapter, r: Var, c: TypeStore.Content, kids: *std.ArrayList(Kid), ids: *std.ArrayList(u32)) Error!u32 {
        _ = r;
        const store = a.in.store;
        switch (c) {
            .flex, .rigid, .err, .alias => return a.leaf(&a.var_id, .@"var"),
            .structure => |s| switch (s) {
                .unit => return a.leaf(&a.cross_id, .cross),
                .func => return a.leaf(&a.closure_id, .closure),
                .empty_record => return a.structural(.record, 0, &.{}),
                .tuple => |t| {
                    kids.clearRetainingCapacity();
                    for (store.vars(t), 0..) |e, k| try kids.append(a.gpa, .{ .step = try Step.index(a.account, @intCast(k)), .id = try a.childId(e) });
                    return a.structural(.tuple, t.len, kids.items);
                },
                .record => |rec| {
                    // The fields along the extension chain.
                    var local: std.ArrayList(Kid) = .empty;
                    defer local.deinit(a.gpa);
                    var at = rec;
                    while (true) {
                        for (store.fields(at.fields)) |fld| try local.append(a.gpa, .{ .step = try Step.field(a.account, a.rank(fld.name)), .id = try a.childId(fld.value) });
                        switch (store.resolvedContent(at.ext)) {
                            .structure => |es| switch (es) {
                                .record => |next| at = next,
                                else => break,
                            },
                            else => break,
                        }
                    }
                    sortKids(local.items);
                    return a.structural(.record, 0, local.items);
                },
                .app => |ap| {
                    ids.clearRetainingCapacity();
                    for (store.vars(ap.args)) |arg| try ids.append(a.gpa, try a.childId(arg));
                    return a.nominal(ap.type, ids.items, none);
                },
            },
        }
    }

    fn sortKids(kids: []Kid) void {
        std.mem.sort(Kid, kids, {}, struct {
            fn lessThan(_: void, x: Kid, y: Kid) bool {
                return x.step.word() < y.step.word();
            }
        }.lessThan);
    }

    // ---- templates -------------------------------------------------------------

    /// The id of BIR type instruction `inst` of module `m` under `env` (an
    /// argument list), read within nominal type `within`'s payloads: a
    /// tree, post-order on an explicit stack.
    fn ofTerm(a: *Adapter, m: u32, inst: Bir.Inst.Index, env: u32, within: u32) Error!u32 {
        const bir = a.in.birs[m];
        const Frame = struct { inst: Bir.Inst.Index, expanded: bool };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(a.gpa);
        var done: stamped.Column(u32, u32) = .{};
        defer done.deinit(a.gpa);
        var ops: std.ArrayList(Bir.Inst.Index) = .empty;
        defer ops.deinit(a.gpa);
        try stack.append(a.gpa, .{ .inst = inst, .expanded = false });
        while (stack.pop()) |f| {
            if (done.contains(f.inst.int())) continue;
            if (!f.expanded) {
                try stack.append(a.gpa, .{ .inst = f.inst, .expanded = true });
                ops.clearRetainingCapacity();
                try bir.operands(a.gpa, f.inst, &ops);
                for (ops.items) |o| try stack.append(a.gpa, .{ .inst = o, .expanded = false });
                continue;
            }
            try done.put(a.gpa, f.inst.int(), try a.closeTerm(m, f.inst, env, within, &done));
        }
        return done.get(inst.int()).?;
    }

    fn closeTerm(a: *Adapter, m: u32, inst: Bir.Inst.Index, env: u32, within: u32, done: *stamped.Column(u32, u32)) Error!u32 {
        const bir = a.in.birs[m];
        const d = bir.instData(inst);
        const tag = bir.instTag(inst);
        switch (tag) {
            .type_var => {
                const p = Bir.TypeVarInfo.unpack(d.rhs).param;
                if (p == Bir.TypeVarInfo.param_none) return a.leaf(&a.var_id, .@"var");
                const id = a.listAt(env, p);
                return if (id == none) a.leaf(&a.var_id, .@"var") else id;
            },
            .type_unit => return a.leaf(&a.cross_id, .cross),
            .type_fn => return a.leaf(&a.closure_id, .closure),
            .type_tuple => {
                var kids: std.ArrayList(Kid) = .empty;
                defer kids.deinit(a.gpa);
                const elems = bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index);
                for (elems, 0..) |e, k| try kids.append(a.gpa, .{ .step = try Step.index(a.account, @intCast(k)), .id = done.get(e.int()).? });
                return a.structural(.tuple, @intCast(elems.len), kids.items);
            },
            .type_record, .type_record_ext => {
                var kids: std.ArrayList(Kid) = .empty;
                defer kids.deinit(a.gpa);
                const r = if (tag == .type_record) Bir.inlineRange(d) else bir.subRange(@fromBackingInt(d.rhs));
                for (bir.extraSlice(r, Bir.Field)) |fld| try kids.append(a.gpa, .{ .step = try Step.field(a.account, a.rank(bir.symbol(fld.name))), .id = done.get(fld.value.int()).? });
                sortKids(kids.items);
                return a.structural(.record, 0, kids.items);
            },
            .type_app => {
                var args: std.ArrayList(u32) = .empty;
                defer args.deinit(a.gpa);
                for (bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index)) |e| try args.append(a.gpa, done.get(e.int()).?);
                const head: Bir.Inst.Index = @fromBackingInt(d.lhs);
                return a.applied(m, a.in.types.headId(@fromBackingInt(m), bir.instTag(head), bir.instData(head)), args.items, env, within);
            },
            else => {
                const t = a.in.types.headId(@fromBackingInt(m), tag, d);
                if (t == .none) return a.leaf(&a.var_id, .@"var");
                return a.applied(m, t, &.{}, env, within);
            },
        }
    }

    /// A nominal type applied in a template: an alias expanded under its
    /// arguments, a non-regular recursion folded onto its head.
    fn applied(a: *Adapter, m: u32, t: Types.TypeId, args: []const u32, env: u32, within: u32) Error!u32 {
        _ = m;
        if (t == .none or t.int() >= a.in.types.entries.len) return a.leaf(&a.var_id, .@"var");
        const e = a.in.types.entries[t.int()];
        if (e.kind == .alias and !e.schema_endpoint) {
            const bir = a.in.birs[e.module.int()];
            const body = bir.decl(e.decl).annotation.unwrap() orelse return a.leaf(&a.var_id, .@"var");
            return a.ofTerm(e.module.int(), body, try a.listOf(args), within);
        }
        _ = env;
        // The same head up the chain of payloads that named this one, with
        // other arguments: a non-regular type (mutual ones too), folded.
        const list = try a.listOf(args);
        var x = within;
        while (x != none) : (x = a.nodes.items[x].origin) {
            const n = a.nodes.items[x];
            if (n.kind != .nominal or n.head != t.int() or n.a == list) continue;
            const vars = try a.gpa.alloc(u32, args.len);
            defer a.gpa.free(vars);
            @memset(vars, try a.leaf(&a.var_id, .@"var"));
            return a.nominal(t, vars, within);
        }
        return a.nominal(t, args, within);
    }

    // ---- describing a node -------------------------------------------------------

    fn isPrimitive(a: *const Adapter, t: Types.TypeId) bool {
        const wk = a.in.types.well_known;
        return t == wk.int or t == wk.float or t == wk.char or t == wk.string;
    }

    fn crossingWord(bir: *const Bir, d: Bir.Decl) bool {
        for (bir.ownSlotsV2(d)) |s| if (s[0] == Bir.own_type and s[1] & Ast.OwnWord.crossing.bit() != 0) return true;
        return false;
    }

    fn describe(ctx: *anyopaque, id: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const a: *Adapter = @ptrCast(@alignCast(ctx));
        return a.describeOr(id, out) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // A limit met while describing: the node is a leaf that may hold
            // anything; the account has the failure and stops the owner.
            else => .{ .kind = .@"var" },
        };
    }

    fn describeOr(a: *Adapter, id: u32, out: *std.ArrayList(Place.Child)) Error!Place.Description {
        const n = a.nodes.items[id];
        switch (n.kind) {
            .structural, .cyclic => {
                for (a.kids.items[n.a..][0..n.b]) |k| try out.append(a.gpa, .{ .step = k.step, .@"var" = k.id });
                return .{ .kind = n.place_kind, .head = n.head };
            },
            .nominal => {},
        }
        const t: Types.TypeId = @fromBackingInt(n.head);
        const e = a.in.types.entries[t.int()];
        const arg0 = a.listAt(n.a, 0);
        if (e.schema_endpoint) return .{ .kind = .@"opaque", .head = n.head };
        const bir = a.in.birs[e.module.int()];
        const decl = bir.decl(e.decl);
        switch (decl.own_kind) {
            .sequence => if (arg0 != none) {
                try out.append(a.gpa, .{ .step = Step.elem, .@"var" = arg0 });
                return .{ .kind = .list, .head = n.head };
            },
            .cell => if (arg0 != none) {
                try out.append(a.gpa, .{ .step = Step.contents, .@"var" = arg0 });
                return .{ .kind = .ref, .head = n.head };
            },
            else => {},
        }
        switch (e.kind) {
            .foreign => {
                // Its head, so a block names which type crosses (§2.1).
                if (a.isPrimitive(t) or crossingWord(bir, decl)) return .{ .kind = .cross, .head = n.head };
                return .{ .kind = .@"opaque", .head = n.head };
            },
            .alias => return .{ .kind = .@"var" },
            .adt => {
                for (bir.declCtors(decl), 0..) |c, ord| {
                    for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index), 0..) |arg, k| {
                        const step = try a.places.ctorStep(a.gpa, a.account, @intCast(ord), @intCast(k));
                        try out.append(a.gpa, .{ .step = step, .@"var" = try a.ofTerm(e.module.int(), arg, n.a, id) });
                    }
                }
                return .{ .kind = .ctor, .head = n.head };
            },
        }
    }

    pub fn source(a: *Adapter) Place.Source {
        return .{ .ctx = a, .describe = describe };
    }

    pub fn placeOfVar(a: *Adapter, v: Var.Optional) Error!PlaceId {
        const id = if (v.unwrap()) |x| try a.ofVar(x) else try a.leaf(&a.var_id, .@"var");
        return a.places.of(a.gpa, a.account, a.source(), id);
    }

    /// The module's own place equal to `p`, a block's (§2.1: a block's
    /// place re-interned onto the reader's graph, which is the same graph
    /// because both were built from one definition), when its structure
    /// names this adapter's node: a nominal type of no parameters, a
    /// sequence or a cell of a named element, a record or a tuple of named
    /// fields, a leaf. A parameterised constructor type's arguments are not
    /// in a block, so its place stays the block's (S6, #1317). Checked by
    /// `Place.equals`, so a node that differs is never taken for `p`.
    pub fn ownPlace(a: *Adapter, p: PlaceId) Error!?PlaceId {
        const places = a.places;
        const pending = none - 1;
        var memo: stamped.Column(PlaceId, u32) = .{};
        defer memo.deinit(a.gpa);
        var stack: std.ArrayList(struct { p: PlaceId, expanded: bool }) = .empty;
        defer stack.deinit(a.gpa);
        var kids: std.ArrayList(Kid) = .empty;
        defer kids.deinit(a.gpa);
        try stack.append(a.gpa, .{ .p = p, .expanded = false });
        while (stack.pop()) |f| {
            // A place met again while its parts are read (a cycle no nominal
            // type closes) names nothing.
            if (memo.get(f.p)) |m| if (m != pending or !f.expanded) continue;
            const k = places.kind(f.p);
            const h = places.head(f.p);
            const st = places.steps(f.p);
            // A crossing type by its head; `⊤`, whose head is none, a leaf.
            const nominal_kind = k == .ctor or k == .list or k == .ref or k == .@"opaque" or (k == .cross and h != none);
            const arity: u32 = if (nominal_kind and h < a.in.types.entries.len) a.in.types.entries[h].arity else 0;
            // What the node needs first: a sequence's or a cell's element,
            // a record's or a tuple's fields.
            const needs = (k == .record or k == .tuple) or ((k == .list or k == .ref) and arity == 1 and st.steps.len == 1);
            if (needs and !f.expanded) {
                try memo.put(a.gpa, f.p, pending);
                try stack.append(a.gpa, .{ .p = f.p, .expanded = true });
                for (st.children) |c| if (!memo.contains(c)) try stack.append(a.gpa, .{ .p = c, .expanded = false });
                continue;
            }
            const node: u32 = if (needs) blk: {
                kids.clearRetainingCapacity();
                for (st.steps, st.children) |s, c| {
                    const id = memo.get(c) orelse none;
                    if (id == none or id == pending) break :blk none;
                    try kids.append(a.gpa, .{ .step = s, .id = id });
                }
                break :blk if (k == .record or k == .tuple) try a.structural(k, h, kids.items) else try a.nominal(@fromBackingInt(h), &.{kids.items[0].id}, none);
            } else if (nominal_kind and h < a.in.types.entries.len and arity == 0)
                try a.nominal(@fromBackingInt(h), &.{}, none)
            else if (st.steps.len == 0) switch (k) {
                .@"var" => try a.leaf(&a.var_id, .@"var"),
                .cross => try a.leaf(&a.cross_id, .cross),
                .closure => try a.leaf(&a.closure_id, .closure),
                else => none,
            } else none;
            try memo.put(a.gpa, f.p, node);
        }
        const node = memo.get(p).?;
        if (node == none) return null;
        const q = try places.of(a.gpa, a.account, a.source(), node);
        if (q != p and !try Place.Table.equals(places, p, places, q, a.gpa, .growth(a.account))) return null;
        return q;
    }
};

// ---------------------------------------------------------------------------
// The module
// ---------------------------------------------------------------------------

/// One declaration's answer.
pub const DeclResult = struct {
    decl: u32,
    class: ClassId = .none,
    unbuilt: u32 = none,
    lines: []Walk.Line = &.{},
    /// The account's failure, when it stopped the walk.
    failure: ?Ids.Failure = null,
    account: Ids.Account = .{},
};

pub const Module = struct {
    in: *const Input,
    gpa: Allocator,
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    conds: Cond.Table,
    sums: Summary.Table = .{},
    /// The environments of the views calls answer (§2.11), read by `shapes`.
    views: Calls.Views = undefined,
    adapter: Adapter,
    /// The account of the declaration being walked.
    account: *Ids.Account,
    /// `shared` indices: `(module, decl)` interned.
    shared: Ids.FixedDict(2) = .{},
    shared_of: std.ArrayList([2]u32) = .empty,
    results: std.ArrayList(DeclResult) = .empty,
    /// Per declaration of the module: its index in `results`, or `none`.
    result_of: []u32 = &.{},
    prepass_arena: std.heap.ArenaAllocator,
    /// The local index the walked declaration's locals start at.
    cur_locals: u32 = 0,
    /// What the module itself is charged: the condition table's constants.
    base_account: Ids.Account = .{},
    /// Per imported module read, its classes by declaration (`Imports`);
    /// null for one with no block that decodes. Read at its first call.
    imported: stamped.Column(u32, ?[]ClassId) = .{},
    imported_owned: std.ArrayList([]ClassId) = .empty,
    /// A block's instruction `(module, inst)` → this module's id for it, past
    /// its own instructions: a namespace no instruction of the module or of
    /// another import meets (`Block.Remap.inst`).
    import_insts: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,

    pub fn deinit(mod: *Module) void {
        const gpa = mod.gpa;
        mod.places.deinit(gpa);
        mod.cells.deinit(gpa);
        mod.shapes.deinit(gpa);
        mod.conds.deinit(gpa);
        mod.sums.deinit(gpa);
        mod.views.deinit(gpa);
        mod.adapter.deinit();
        mod.shared.deinit(gpa);
        mod.shared_of.deinit(gpa);
        for (mod.results.items) |*r| {
            gpa.free(r.lines);
            r.account.deinit(gpa);
        }
        mod.results.deinit(gpa);
        gpa.free(mod.result_of);
        mod.prepass_arena.deinit();
        mod.base_account.deinit(gpa);
        for (mod.imported_owned.items) |cs| gpa.free(cs);
        mod.imported_owned.deinit(gpa);
        mod.imported.deinit(gpa);
        mod.import_insts.deinit(gpa);
    }

    /// The `shared` index of declaration `md` (a block's shared cell).
    pub fn sharedOf(mod: *Module, md: [2]u32) Allocator.Error!u32 {
        const got = try mod.shared.getOrPut(mod.gpa, md);
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(mod.shared_of.items.len);
            try mod.shared_of.append(mod.gpa, md);
        }
        return got.value_ptr.*;
    }

    /// Block instruction `inst` of module `m` in this module's namespace.
    pub fn importInst(mod: *Module, m: u32, inst: u32) Allocator.Error!u32 {
        const got = try mod.import_insts.getOrPut(mod.gpa, .{ m, inst });
        if (!got.found_existing) got.value_ptr.* = @intCast(mod.in.bir.insts.len + mod.import_insts.count() - 1);
        return got.value_ptr.*;
    }

    /// The class declaration `di` of module `m` publishes for its importers,
    /// read from `m`'s block at the first call (§2.11: an imported call is a
    /// same-module one); null when it publishes none they may apply.
    fn importedClass(mod: *Module, m: u32, di: u32) Error!?ClassId {
        const imports = mod.in.imports orelse return null;
        if (!mod.imported.contains(m)) {
            const cs = try imports.read(imports.ctx, mod, m);
            if (cs) |c| mod.imported_owned.append(mod.gpa, c) catch |err| {
                mod.gpa.free(c);
                return err;
            };
            try mod.imported.put(mod.gpa, m, cs);
        }
        const cs = mod.imported.get(m).? orelse return null;
        return if (di < cs.len and cs[di] != .none) cs[di] else null;
    }

    pub fn env(mod: *Module) Summary.Env {
        return .{ .gpa = mod.gpa, .charge = .growth(mod.account), .places = &mod.places, .cells = &mod.cells, .shapes = &mod.shapes, .conds = &mod.conds };
    }

    /// The `(module, decl)` a `shared` index names.
    pub fn sharedDecl(mod: *const Module, idx: u32) [2]u32 {
        return mod.shared_of.items[idx];
    }

    // ---- the context Transfer reads ---------------------------------------------

    fn self(ctx: *anyopaque) *Module {
        return @ptrCast(@alignCast(ctx));
    }

    fn placeOfInst(ctx: *anyopaque, inst: u32) Error!PlaceId {
        const mod = self(ctx);
        const v: Var.Optional = if (inst < mod.in.inst_type.len) mod.in.inst_type[inst] else .none;
        return mod.adapter.placeOfVar(v);
    }

    fn placeOfLocal(ctx: *anyopaque, local: u32) Error!PlaceId {
        const mod = self(ctx);
        const v: Var.Optional = if (mod.cur_locals + local < mod.in.local_type.len) mod.in.local_type[mod.cur_locals + local] else .none;
        return mod.adapter.placeOfVar(v);
    }

    fn fieldRank(ctx: *anyopaque, s: Bir.SymbolIndex) u32 {
        const mod = self(ctx);
        return mod.adapter.rank(mod.in.bir.symbol(s));
    }

    /// The `(module, decl)` a value reference names, or null.
    pub fn declOfCtx(ctx: *anyopaque, inst: u32) ?[2]u32 {
        return self(ctx).declOf(inst);
    }

    pub fn declOf(mod: *const Module, inst: u32) ?[2]u32 {
        const bir = mod.in.bir;
        const d = bir.instData(@fromBackingInt(inst));
        return switch (bir.instTag(@fromBackingInt(inst))) {
            .top => .{ mod.in.module, d.lhs },
            .ext_value => blk: {
                if (d.lhs >= mod.in.provenance.len) break :blk null;
                const decl = mod.in.provenance[d.lhs].valueDecl(d.rhs) orelse break :blk null;
                break :blk .{ d.lhs, decl.int() };
            },
            .method_call => mod.methodTarget(inst),
            else => null,
        };
    }

    /// The declaration a method call dispatches to, when it is one.
    fn methodTarget(mod: *const Module, inst: u32) ?[2]u32 {
        const dt = mod.in.dispatch orelse return null;
        const site = dt.siteOf(@fromBackingInt(inst)) orelse return null;
        const ti = site.callee.unwrap() orelse return null;
        return switch (dt.term(ti)) {
            .top => |u| .{ mod.in.module, u.decl.int() },
            .ext => |u| if (mod.in.provenance.len > u.module.int()) if (mod.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| .{ u.module.int(), d.int() } else null else null,
            else => null,
        };
    }

    /// The `(module, constructor index)` a constructor reference names, or
    /// null: what a line calls a constructor application by (`<Node …>`).
    pub fn ctorIndexCtx(ctx: *anyopaque, ref: u32) ?[2]u32 {
        const mod = self(ctx);
        const bir = mod.in.bir;
        const d = bir.instData(@fromBackingInt(ref));
        const at: [2]u32 = switch (bir.instTag(@fromBackingInt(ref))) {
            .ctor => .{ mod.in.module, d.lhs },
            .ext_ctor => if (d.lhs < mod.in.provenance.len and d.rhs < mod.in.provenance[d.lhs].ctor_index.len) .{ d.lhs, mod.in.provenance[d.lhs].ctor_index[d.rhs] } else return null,
            else => return null,
        };
        return if (at[0] < mod.in.birs.len and at[1] < mod.in.birs[at[0]].ctors.len) at else null;
    }
    fn ctorOf(ctx: *anyopaque, ref: u32) ?[2]u32 {
        const mod = self(ctx);
        const bir = mod.in.bir;
        const d = bir.instData(@fromBackingInt(ref));
        const m, const index = switch (bir.instTag(@fromBackingInt(ref))) {
            .ctor => .{ mod.in.module, d.lhs },
            .ext_ctor => blk: {
                if (d.lhs >= mod.in.provenance.len) return null;
                const p = mod.in.provenance[d.lhs];
                if (d.rhs >= p.ctor_index.len) return null;
                break :blk .{ d.lhs, p.ctor_index[d.rhs] };
            },
            else => return null,
        };
        const owner = mod.in.birs[m];
        if (index >= owner.ctors.len) return null;
        const c = owner.ctors[index];
        const decl = owner.decl(c.decl);
        return .{ index - decl.ctors_start, @backingInt(c.args_end) - @backingInt(c.args_start) };
    }

    fn sharedIndex(ctx: *anyopaque, ref: u32) ?u32 {
        const mod = self(ctx);
        const md = mod.declOf(ref) orelse return null;
        const decl = mod.in.birs[md[0]].decls[md[1]];
        if (decl.kind != .value or decl.params != 0) return null;
        const at = placeOfInst(ctx, ref) catch return null;
        if (mod.places.kind(at) == .closure) return null;
        return mod.sharedOf(md) catch null;
    }

    fn isListAppend(ctx: *anyopaque, inst: u32) bool {
        const mod = self(ctx);
        const dt = mod.in.dispatch orelse return false;
        return dt.isListAppend(@fromBackingInt(inst)) or dt.isListAppend(@fromBackingInt(mod.in.bir.instData(@fromBackingInt(inst)).lhs));
    }

    /// The arguments of a call or a method call (the receiver first).
    fn argsOf(mod: *const Module, inst: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
        const bir = mod.in.bir;
        const d = bir.instData(@fromBackingInt(inst));
        if (bir.instTag(@fromBackingInt(inst)) == .call) {
            for (bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index)) |x| try out.append(mod.gpa, x.int());
            return;
        }
        try out.append(mod.gpa, d.lhs);
        const m = bir.extraData(@fromBackingInt(d.rhs), Bir.MethodCall);
        for (bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Bir.Inst.Index)) |x| try out.append(mod.gpa, x.int());
    }

    fn callee(ctx: *anyopaque, inst: u32) Error!Transfer.Callee {
        const mod = self(ctx);
        const bir = mod.in.bir;
        var target: ?[2]u32 = null;
        // A comparison whose class is its components' (§2.13.13): derived or
        // primitive, or a container's in core.
        var composed = false;
        var term: ?Dispatch.TermIndex = null;
        if (bir.instTag(@fromBackingInt(inst)) == .call) {
            const head = bir.instData(@fromBackingInt(inst)).lhs;
            if (ctorOf(ctx, head)) |c| return .{ .ctor = c[0] };
            target = mod.declOf(head);
        } else if (mod.in.dispatch) |dt| if (dt.siteOf(@fromBackingInt(inst))) |site| if (site.callee.unwrap()) |ti| {
            term = ti;
            switch (dt.term(ti)) {
                .top => |u| target = .{ mod.in.module, u.decl.int() },
                .ext => |u| if (mod.in.provenance.len > u.module.int()) if (mod.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| {
                    target = .{ u.module.int(), d.int() };
                },
                // A derived or primitive `eq`/`compare` (§2.13.13): its class
                // composes its components'.
                // A parameter's or a codec's names no function here.
                .param, .codec => {},
                else => composed = true,
            }
        };
        var args: std.ArrayList(u32) = .empty;
        defer args.deinit(mod.gpa);
        try mod.argsOf(inst, &args);
        if (target) |t| {
            const owner = mod.in.birs[t[0]];
            const words = owner.ownSlotsV2(owner.decls[t[1]]);
            if (words.len != 0) return .{ .class = try mod.wordedClass(words, args.items, inst, t[0], owner.decls[t[1]]) };
            // A container's `eq`/`compare` in core (`List.eq`, written over
            // its element evidence): its class is its components', whatever
            // block it publishes, so the evidence it is handed is read.
            if (mod.in.isCore(t[0]) and bir.instTag(@fromBackingInt(inst)) == .method_call) {
                const m = bir.extraData(@fromBackingInt(@intCast(bir.instData(@fromBackingInt(inst)).rhs)), Bir.MethodCall);
                if (m.origin != .none) composed = true;
            }
            if (!composed) {
                // A declaration of this module walked before this one (an
                // earlier group, §8 S3b): its class, applied at this call. One
                // of this group (recursion) or one past its limit is not built
                // here.
                if (t[0] == mod.in.module) if (mod.walkedClass(t[1])) |c| return .{ .class = c };
                // One of another module (S3b slice 3): the class its block
                // publishes, applied the same way.
                if (t[0] != mod.in.module) if (try mod.importedClass(t[0], t[1])) |c| return .{ .class = c };
            }
        }
        // Evidence that names no function (a parameter's, a codec) hides its
        // components.
        if (composed) if (term) |ti| if (mod.in.dispatch) |dt| if (try mod.opaqueEvidence(dt, ti, inst)) {
            composed = false;
        };
        if (composed and args.items.len == 2) {
            var comps: std.ArrayList(ClassId) = .empty;
            defer comps.deinit(mod.gpa);
            // A user-written comparison reached through the type with no class
            // leaves the call unbuilt: nothing is known of what it writes.
            const at = try placeOfInst(ctx, args.items[0]);
            if (try mod.componentClasses(at, inst, &comps)) {
                return .{ .class = try Rows.derivedClass(mod.env(), &mod.sums, at, try placeOfInst(ctx, inst), comps.items) };
            }
        }
        // Every argument and the result cross: nothing to track.
        if (mod.places.kind(try placeOfInst(ctx, inst)) != .cross) return .unbuilt;
        for (args.items) |x| if (mod.places.kind(try placeOfInst(ctx, x)) != .cross) return .unbuilt;
        // A call of a function value is S4's, whatever it is handed.
        if (target == null and bir.instTag(@fromBackingInt(inst)) == .call) return .unbuilt;
        return .harmless;
    }

    /// The class of declaration `di`'s walk when it is done, built and within its
    /// limits; null before its walk, or when a limit stopped it.
    pub fn walkedClass(mod: *const Module, di: u32) ?ClassId {
        if (di >= mod.result_of.len or mod.result_of[di] == none) return null;
        const r = mod.results.items[mod.result_of[di]];
        // An unbuilt walk's class is the pessimistic one: applying it would
        // check the call against a class the callee never earned.
        if (r.failure != null or r.unbuilt != none or r.class == .none) return null;
        return r.class;
    }
    fn isSequence(mod: *const Module, at: PlaceId) bool {
        return mod.places.kind(at) == .list and mod.places.child(at, Step.elem) != null;
    }

    fn isCell(mod: *const Module, at: PlaceId) bool {
        return mod.places.kind(at) == .ref and mod.places.child(at, Step.contents) != null;
    }

    /// Whether an evidence root of the comparison at `inst` is opaque: a
    /// parameter's or a codec, anywhere in it.
    fn opaqueEvidence(mod: *const Module, dt: *const Dispatch, ti: Dispatch.TermIndex, inst: u32) Allocator.Error!bool {
        var stack: std.ArrayList(Dispatch.TermIndex) = .empty;
        defer stack.deinit(mod.gpa);
        // Evidence is a DAG (`EvidenceDagBuildDepth32`): each term once.
        var seen: stamped.Column(Dispatch.TermIndex, void) = .{};
        defer seen.deinit(mod.gpa);
        try stack.appendSlice(mod.gpa, dt.argsOfTerm(ti));
        if (dt.siteOf(@fromBackingInt(inst))) |site| try stack.appendSlice(mod.gpa, dt.argsAt(site.evidence));
        while (stack.pop()) |t| {
            if (seen.contains(t)) continue;
            try seen.put(mod.gpa, t, {});
            switch (dt.term(t)) {
                .param, .codec => return true,
                else => try stack.appendSlice(mod.gpa, dt.argsOfTerm(t)),
            }
        }
        return false;
    }

    /// The classes of the user-written `eq`/`compare` the comparison at
    /// `inst` reaches through its first argument's type (§2.13.13): its
    /// derived row calls each nominal component's own. False when one has no
    /// class an importer or this module may apply.
    fn componentClasses(mod: *Module, root: PlaceId, inst: u32, out: *std.ArrayList(ClassId)) Error!bool {
        const interner = mod.in.interner orelse return false;
        const bir = mod.in.bir;
        const name: []const u8 = blk: {
            if (bir.instTag(@fromBackingInt(inst)) != .method_call) break :blk "";
            const m = bir.extraData(@fromBackingInt(@intCast(bir.instData(@fromBackingInt(inst)).rhs)), Bir.MethodCall);
            break :blk switch (m.origin) {
                .eq, .neq => "eq",
                .lt, .le, .gt, .ge => "compare",
                .none => interner.slice(bir.symbol(m.name)),
            };
        };
        var seen: stamped.Column(u32, void) = .{};
        defer seen.deinit(mod.gpa);
        var stack: std.ArrayList(PlaceId) = .empty;
        defer stack.deinit(mod.gpa);
        try stack.append(mod.gpa, root);
        while (stack.pop()) |p| {
            if (seen.contains(p.int())) continue;
            try seen.put(mod.gpa, p.int(), {});
            if (mod.places.kind(p) == .ctor and mod.places.head(p) < mod.in.types.entries.len) {
                const m = mod.in.types.entries[mod.places.head(p)].module.int();
                if (!mod.in.isCore(m)) if (userComparison(mod.in, interner, m, name)) |di| {
                    const c = (if (m == mod.in.module) mod.walkedClass(di) else try mod.importedClass(m, di)) orelse return false;
                    try out.append(mod.gpa, c);
                };
            }
            try stack.appendSlice(mod.gpa, mod.places.steps(p).children);
        }
        return true;
    }

    /// The `pub` value `name` of module `m`, a type's method by the rule of
    /// §2.13.13 ("the `pub` values of the module declaring it").
    fn userComparison(in: *const Input, interner: *const InternPool.Global, m: u32, name: []const u8) ?u32 {
        const bir = in.birs[m];
        for (bir.decls, 0..) |d, di| {
            if (d.kind != .value or !d.is_pub) continue;
            if (std.mem.eql(u8, interner.slice(bir.symbol(d.name)), name)) return @intCast(di);
        }
        return null;
    }

    /// A worded declaration's class at this call (§5's signature adapter):
    /// its words over the call's own argument and result places.
    fn wordedClass(mod: *Module, words: []const [2]u32, args: []const u32, inst: u32, owner: u32, decl: Bir.Decl) Error!ClassId {
        const gpa = mod.gpa;
        var params: std.ArrayList(Rows.Param) = .empty;
        defer params.deinit(gpa);
        var result_words: u32 = 0;
        for (args, 0..) |x, k| {
            const at = try placeOfInst(mod, x);
            var w: u32 = 0;
            for (words) |s| if (s[0] == k) {
                w = s[1];
            };
            try params.append(gpa, .{ .place = at, .words = w, .fn_params = if (mod.places.kind(at) == .closure) &.{} else null, .type_variable = try paramIsTypeVariable(mod.in, owner, decl, k) });
        }
        for (words) |s| if (s[0] == Bir.own_result) {
            result_words = s[1];
        };
        return Rows.fromWords(mod.env(), &mod.sums, .{ .params = params.items, .result = try placeOfInst(mod, inst), .result_words = result_words });
    }

    pub fn context(mod: *Module) Transfer.Context {
        return .{
            .ctx = mod,
            .placeOfInst = placeOfInst,
            .placeOfLocal = placeOfLocal,
            .fieldRank = fieldRank,
            .callee = callee,
            .ctorOf = ctorOf,
            .sharedIndex = sharedIndex,
            .isListAppend = isListAppend,
        };
    }
};

/// Check every declaration of a module (§8 S3a): a worded one is its row,
/// any other value with a body is walked, in the pre-pass's group order.
/// The module owns its answer. A declaration the summary-size limit stops
/// is checked again alone, in fresh tables, and refused only if that cold
/// run is stopped too (§4.4, #1104): the module's shared tables charge a
/// first miss to whoever meets it, so a warm account depends on where the
/// declaration sits, a cold one never. Its account is then the cold run's;
/// `cold_accounts` (the dump's) makes every declaration's so.
pub fn checkModule(in: *const Input, mod: *Module, cold_accounts: bool) Allocator.Error!void {
    const gpa = in.gpa;
    try initModule(in, mod);
    const prepass = try Prepass.run(gpa, mod.prepass_arena.allocator(), .{ .bir = in.bir, .dispatch = in.dispatch });
    var pool: ColdPool = .{};
    defer pool.deinit(gpa);
    for (prepass.order) |di| {
        const d = in.bir.decls[di];
        if (d.kind != .value or d.body == .none) continue;
        if (in.bir.ownSlotsV2(d).len != 0) continue; // a row: its class is its words'
        // R_f (§4.4): the declaration's `@ownership_summary_size`, else the
        // module's, else the default.
        const allowance = if (d.summary_size != 0) d.summary_size else if (in.bir.summary_size != 0) in.bir.summary_size else Ids.Account.default_allowance;
        try mod.results.append(gpa, .{ .decl = di, .account = .{ .allowance = allowance } });
        mod.result_of[di] = @intCast(mod.results.items.len - 1);
        const r = &mod.results.items[mod.results.items.len - 1];
        try walkIn(mod, d, &prepass, r);
        const stopped = r.failure != null and r.failure.? == .exhausted;
        if (!stopped and !cold_accounts) continue;
        var cold: DeclResult = .{ .decl = di, .account = .{ .allowance = allowance } };
        errdefer cold.account.deinit(gpa);
        try coldRun(mod, &pool, di, &prepass, &cold);
        if (stopped and cold.failure == null) {
            // Within the limit alone: walked again here, unbounded, for its
            // class and lines in this module's tables.
            gpa.free(r.lines);
            r.account.deinit(gpa);
            r.* = .{ .decl = di, .account = .{ .allowance = std.math.maxInt(u32) - 1 } };
            try walkIn(mod, d, &prepass, r);
        }
        r.account.deinit(gpa);
        r.account = cold.account;
        if (stopped) r.failure = cold.failure;
    }
    mod.account = &mod.base_account;
    mod.adapter.account = &mod.base_account;
}

/// The cold run's tables (§4.4, #1104): a module holding exactly the walks
/// of a set of declarations, each once. A cold run whose callees include
/// that set reuses it and walks only what is missing; any other starts
/// afresh. So a dump's cold accounts cost each walk once along a chain of
/// calls, and each cold run's tables hold exactly its callees' walks.
const ColdPool = struct {
    mod: ?*Module = null,
    walked: []bool = &.{},

    fn deinit(p: *ColdPool, gpa: Allocator) void {
        if (p.mod) |m| {
            m.deinit();
            gpa.destroy(m);
        }
        gpa.free(p.walked);
        p.* = .{};
    }
};

/// `di` walked cold on `cold`'s account, after every declaration of an
/// earlier group it reaches by calls (`.top` references and dispatched
/// method calls). A callee the warm run stopped at a limit, or left
/// unbuilt, is not walked: the cold run applies no class for it either.
fn coldRun(mod: *Module, pool: *ColdPool, di: u32, prepass: *const Facts.Prepass, cold: *DeclResult) Allocator.Error!void {
    const gpa = mod.gpa;
    const in = mod.in;
    const bir = in.bir;
    const reached = try gpa.alloc(bool, bir.decls.len);
    defer gpa.free(reached);
    @memset(reached, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, di);
    while (stack.pop()) |x| {
        const d = bir.decls[x];
        for (d.inst_start.int()..d.inst_end.int()) |i| {
            const md = mod.declOf(@intCast(i)) orelse continue;
            const t = md[1];
            if (md[0] != in.module or t >= bir.decls.len or reached[t] or prepass.group_of[t] >= prepass.group_of[di]) continue;
            reached[t] = true;
            try stack.append(gpa, t);
        }
    }
    // Reuse the pool only when everything it holds is a callee of `di`.
    if (pool.mod != null) for (pool.walked, 0..) |w, x| if (w and !reached[x]) {
        pool.deinit(gpa);
        break;
    };
    if (pool.mod == null) {
        const m = try gpa.create(Module);
        errdefer gpa.destroy(m);
        try initModule(in, m);
        pool.mod = m;
        pool.walked = try gpa.alloc(bool, bir.decls.len);
        @memset(pool.walked, false);
    }
    const alone = pool.mod.?;
    for (prepass.order) |x| {
        if (!reached[x] or pool.walked[x]) continue;
        pool.walked[x] = true;
        const d = bir.decls[x];
        if (d.kind != .value or d.body == .none or bir.ownSlotsV2(d).len != 0) continue;
        const warm = mod.results.items[mod.result_of[x]];
        try alone.results.append(gpa, .{ .decl = x, .account = .{ .allowance = warm.account.allowance } });
        alone.result_of[x] = @intCast(alone.results.items.len - 1);
        const r = &alone.results.items[alone.results.items.len - 1];
        if (warm.failure != null or warm.unbuilt != none) {
            r.failure = warm.failure;
            r.unbuilt = warm.unbuilt;
            continue;
        }
        try walkIn(alone, d, prepass, r);
    }
    try walkIn(alone, bir.decls[di], prepass, cold);
    gpa.free(cold.lines);
    cold.lines = &.{};
    // `di` itself, for the next cold run that calls it.
    pool.walked[di] = true;
    try alone.results.append(gpa, .{ .decl = di, .class = cold.class, .unbuilt = cold.unbuilt, .failure = cold.failure });
    alone.result_of[di] = @intCast(alone.results.items.len - 1);
    alone.account = &alone.base_account;
    alone.adapter.account = &alone.base_account;
}

/// Empty tables for `in`'s module.
fn initModule(in: *const Input, mod: *Module) Allocator.Error!void {
    mod.* = .{
        .in = in,
        .gpa = in.gpa,
        .conds = undefined,
        .adapter = undefined,
        .account = undefined,
        .prepass_arena = .init(in.gpa),
    };
    mod.account = &mod.base_account;
    mod.conds = Cond.Table.init(in.gpa, .growth(&mod.base_account)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    mod.adapter = .{ .in = in, .gpa = in.gpa, .places = &mod.places, .account = &mod.base_account };
    mod.views = .{ .places = &mod.places, .cells = &mod.cells, .shapes = &mod.shapes, .conds = &mod.conds, .sums = &mod.sums };
    mod.shapes.instantiation = mod.views.instantiation();
    mod.conds.shapes_hook = &mod.shapes;
    mod.conds.resolver = mod.views.resolver();
    mod.shapes.trackRelevance();
    mod.result_of = try in.gpa.alloc(u32, in.bir.decls.len);
    @memset(mod.result_of, none);
}

/// Walk `d` in `mod`'s tables on `r`'s account; a limit is `r`'s failure.
fn walkIn(mod: *Module, d: Bir.Decl, prepass: *const Facts.Prepass, r: *DeclResult) Allocator.Error!void {
    mod.account = &r.account;
    mod.adapter.account = &r.account;
    mod.cur_locals = d.locals_start;
    walkOne(mod, d, prepass, r) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnershipLimit, error.AccountingInvariant => r.failure = r.account.failed,
    };
}

fn walkOne(mod: *Module, d: Bir.Decl, prepass: *const Facts.Prepass, r: *DeclResult) Error!void {
    const gpa = mod.gpa;
    // S_f (§4.1): the written instructions, the source this owner's
    // baseline is proportional to (instrumentation, §4.4).
    r.account.source = d.inst_end.int() - d.inst_start.int();
    var param_places: std.ArrayList(PlaceId) = .empty;
    defer param_places.deinit(gpa);
    const params = mod.in.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index);
    // The parameters' places are the scheme's: a pattern parameter (a
    // tuple, a record, a constructor) has no type of its own.
    const di = r.decl;
    const scheme: Var.Optional = if (di < mod.in.decl_scheme.len) mod.in.decl_scheme[di] else .none;
    if (scheme.unwrap()) |v| switch (mod.in.store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .func => |f| if (mod.in.store.vars(f.params).len == params.len) for (mod.in.store.vars(f.params)) |p| try param_places.append(gpa, try mod.adapter.placeOfVar(p.toOptional())),
            else => {},
        },
        else => {},
    };
    if (param_places.items.len != params.len) {
        param_places.clearRetainingCapacity();
        for (params) |p| {
            const b = mod.in.bir;
            const at = if (b.instTag(p) == .pat_var) try Module.placeOfLocal(mod, b.instData(p).lhs) else try Module.placeOfInst(mod, p.int());
            try param_places.append(gpa, at);
        }
    }
    const result_place = try Module.placeOfInst(mod, d.body.unwrap().?.int());
    var res = try Walk.walk(.{
        .env = mod.env(),
        .sums = &mod.sums,
        .ctx = mod.context(),
        .bir = mod.in.bir,
        .decl = d,
        .prepass = prepass,
        .param_places = param_places.items,
        .result_place = result_place,
    });
    r.class = res.class;
    r.unbuilt = res.unbuilt;
    r.lines = res.lines;
    res.lines = &.{};
}

/// The class a declaration of this module publishes (§3.6): its walk's,
/// or for a worded one or a `foreign` its words' over the places of its
/// own scheme (`Bir.ownSlotsV2`; the pessimistic default without words,
/// R-5.10.3). Null for a declaration that is no value.
pub fn declaredClass(mod: *Module, di: u32) Error!?ClassId {
    const d = mod.in.bir.decls[di];
    if (!d.kind.isValue()) return null;
    for (mod.results.items) |r| if (r.decl == di) return if (r.failure != null) null else r.class;
    const scheme: Var.Optional = if (di < mod.in.decl_scheme.len) mod.in.decl_scheme[di] else .none;
    const v = scheme.unwrap() orelse return null;
    const store = mod.in.store;
    var params: std.ArrayList(Rows.Param) = .empty;
    defer params.deinit(mod.gpa);
    var result: Var.Optional = v.toOptional();
    switch (store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .func => |f| {
                result = f.result.toOptional();
                for (store.vars(f.params)) |p| {
                    const at = try mod.adapter.placeOfVar(p.toOptional());
                    try params.append(mod.gpa, .{ .place = at, .fn_params = if (mod.places.kind(at) == .closure) &.{} else null, .type_variable = try paramIsTypeVariable(mod.in, mod.in.module, d, params.items.len) });
                }
            },
            else => {},
        },
        else => {},
    }
    const words = mod.in.bir.ownSlotsV2(d);
    var result_words: u32 = 0;
    for (words) |s| {
        if (s[0] == Bir.own_result) result_words = s[1];
        if (s[0] < params.items.len) params.items[s[0]].words = s[1];
    }
    return try Rows.fromWords(mod.env(), &mod.sums, .{ .params = params.items, .result = try mod.adapter.placeOfVar(result), .result_words = result_words });
}

/// Whether parameter `k` of declaration `d` of module `owner` is declared
/// as a bare type variable (`borrowed a`), aliases expanded (`Id a` with
/// `type alias Id a = a`): its value may hold any structure, and the callee
/// may read any of it, so its words apply at every depth (§2.13.6, #1105).
fn paramIsTypeVariable(in: *const Input, owner: u32, d: Bir.Decl, k: usize) Allocator.Error!bool {
    const bir = in.birs[owner];
    const ann = d.annotation.unwrap() orelse return false;
    if (bir.instTag(ann) != .type_fn) return false;
    const ps = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(ann).lhs)), Bir.Inst.Index);
    return k < ps.len and try expandsToVariable(in, owner, ps[k]);
}

/// A type written in module `module` whose type variables are bound by
/// `env` (an alias's arguments; null in an annotation, where every variable
/// is free).
const AliasEnv = struct { module: u32, args: []const Bir.Inst.Index, outer: u32 };

/// Whether the type `t` of `module` expands to a free type variable.
/// Alias cycles are refused by the checker (`recursive_alias`), so the
/// expansion ends.
fn expandsToVariable(in: *const Input, start_module: u32, start: Bir.Inst.Index) Allocator.Error!bool {
    // A loop, the environments a list (#1143: aliases chain as long as the
    // source has them). `outer` indexes `envs`; `none` is no environment.
    var envs: std.ArrayList(AliasEnv) = .empty;
    defer envs.deinit(in.gpa);
    var module = start_module;
    var t = start;
    var env: u32 = none;
    while (true) {
        const bir = in.birs[module];
        switch (bir.instTag(t)) {
            .type_var => {
                if (env == none) return true;
                const e = envs.items[env];
                const p = Bir.TypeVarInfo.unpack(bir.instData(t).rhs).param;
                if (p >= e.args.len) return false;
                module = e.module;
                t = e.args[p];
                env = e.outer;
            },
            .type_app => {
                const args = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(t).rhs)), Bir.Inst.Index);
                const alias = aliasOf(in, module, @fromBackingInt(bir.instData(t).lhs)) orelse return false;
                try envs.append(in.gpa, .{ .module = module, .args = args, .outer = env });
                env = @intCast(envs.items.len - 1);
                module = alias[0];
                t = alias[1];
            },
            .type_top, .ext_type => {
                const alias = aliasOf(in, module, t) orelse return false;
                try envs.append(in.gpa, .{ .module = module, .args = &.{}, .outer = env });
                env = @intCast(envs.items.len - 1);
                module = alias[0];
                t = alias[1];
            },
            else => return false,
        }
    }
}

/// The aliased type of the alias a type reference names, with the module
/// it is written in; null for anything else.
fn aliasOf(in: *const Input, module: u32, ref: Bir.Inst.Index) ?struct { u32, Bir.Inst.Index } {
    const bir = in.birs[module];
    const data = bir.instData(ref);
    const at: [2]u32 = switch (bir.instTag(ref)) {
        .type_top => .{ module, data.lhs },
        .ext_type => blk: {
            if (data.lhs >= in.provenance.len) return null;
            const d = in.provenance[data.lhs].typeDecl(data.rhs) orelse return null;
            break :blk .{ data.lhs, d.int() };
        },
        else => return null,
    };
    if (at[0] >= in.birs.len) return null;
    const decls = in.birs[at[0]].decls;
    if (at[1] >= decls.len or decls[at[1]].kind != .type_alias) return null;
    return .{ at[0], decls[at[1]].annotation.unwrap() orelse return null };
}

/// A v2 word on a place without the kind it reads (#1056 item 4): lowering
/// checked its position and companions; whether the type there IS a
/// sequence or a cell needs the types, so it is checked here, against the
/// declaration's own scheme. `slot` is the parameter (`Bir.own_result`).
pub const WordError = struct { decl: u32, slot: u32, word: Ast.OwnWord };

/// Every `WordError` of a module's worded declarations, in declaration and
/// slot order.
pub fn wordKindErrors(mod: *Module, out: *std.ArrayList(WordError)) Error!void {
    const W = Ast.OwnWord;
    for (mod.in.bir.decls, 0..) |d, di| {
        if (!d.kind.isValue()) continue;
        const slots = mod.in.bir.ownSlotsV2(d);
        if (slots.len == 0) continue;
        const scheme: Var.Optional = if (di < mod.in.decl_scheme.len) mod.in.decl_scheme[di] else .none;
        const v = scheme.unwrap() orelse continue;
        var params: std.ArrayList(PlaceId) = .empty;
        defer params.deinit(mod.gpa);
        var result = try mod.adapter.placeOfVar(v.toOptional());
        switch (mod.in.store.resolvedContent(v)) {
            .structure => |s| switch (s) {
                .func => |f| {
                    result = try mod.adapter.placeOfVar(f.result.toOptional());
                    for (mod.in.store.vars(f.params)) |p| try params.append(mod.gpa, try mod.adapter.placeOfVar(p.toOptional()));
                },
                else => {},
            },
            else => {},
        }
        const first: ?PlaceId = if (params.items.len > 0) params.items[0] else null;
        for (slots) |s| {
            const at: ?PlaceId = if (s[0] == Bir.own_result) result else if (s[0] < params.items.len) params.items[s[0]] else null;
            const p = at orelse continue;
            const words = s[1];
            const checks = [_]struct { w: W, ok: bool }{
                .{ .w = .written, .ok = mod.isSequence(p) or mod.isCell(p) or mod.places.kind(p) == .dict },
                .{ .w = .cellread, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .cellwrite, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .cellcomplete, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .cellstored, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .cellupdate, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .cellmodify, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .lent, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .lentoptional, .ok = first != null and mod.isCell(first.?) },
                .{ .w = .cellnew, .ok = mod.isCell(p) },
                .{ .w = .cellempty, .ok = mod.isCell(p) },
                .{ .w = .builderdone, .ok = first != null and mod.isSequence(first.?) },
                .{ .w = .concatenated, .ok = mod.isSequence(p) and params.items.len >= 2 and mod.isSequence(params.items[0]) and mod.isSequence(params.items[1]) },
                .{ .w = .taken, .ok = s[0] != Bir.own_result or (first != null and mod.isSequence(first.?)) },
            };
            for (checks) |c| if (words & c.w.bit() != 0 and !c.ok) try out.append(mod.gpa, .{ .decl = @intCast(di), .slot = s[0], .word = c.w });
        }
    }
}
