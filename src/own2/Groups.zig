//! L13: the module (`docs/design/ownership-v2.md` §2.1, §5, §8 S3a): the
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
const cmp_unseen = none - 1;

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
    order_check: bool = false, // `--ownership-order-check` (test-only)
    rewalk_check: bool = false, // `--ownership-rewalk-check` (test-only)
    contracts: u8 = 0, // `--ownership-contracts` (experiment)
    propagate_dump: bool = false, // `--ownership-propagate` (test-only)

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
    /// `own` is kept across one read, so nested places cost each place once (#1566).
    pub fn ownPlace(a: *Adapter, own: *OwnMemo, p: PlaceId) Error!?PlaceId {
        const places = a.places;
        const pending = none - 1;
        const memo = &own.node;
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
        if (q != p and !try Place.Table.equals(places, p, places, q, a.gpa, .growth(a.account), &own.proven)) return null;
        return q;
    }

    /// `ownPlace`'s memo for one read: a node depends on its place's structure
    /// alone (one reaching a cycle no nominal closes is none from any start).
    pub const OwnMemo = struct {
        node: stamped.Column(PlaceId, u32) = .{},
        proven: Ids.FixedDict(2) = .{},

        pub fn deinit(m: *OwnMemo, gpa: Allocator) void {
            m.node.deinit(gpa);
            m.proven.deinit(gpa);
        }
    };
};

// ---------------------------------------------------------------------------
// The module
// ---------------------------------------------------------------------------

/// One declaration's answer.
pub const DeclResult = struct {
    decl: u32,
    class: ClassId = .none,
    unbuilt: u32 = none,
    /// `unbuilt` calls a member of the declaration's own group at another
    /// instantiation than its own (polymorphic recursion, S4): its own
    /// reason in a dump.
    polymorphic: bool = false,
    /// A recursive group member's walks, 0 for one walked alone.
    walks: u32 = 0,
    /// Of those, the walks the wake rule woke, round 1's included (§8 S3b
    /// slice 4b): every other is the read check's.
    inference: u32 = 0,
    /// The `(edge, delta)` deliveries its class received.
    deliveries: u32 = 0,
    lines: []Walk.Line = &.{},
    /// The account's failure, when it stopped the walk.
    failure: ?Ids.Failure = null,
    account: Ids.Account = .{},
    /// The experiment's contract statistics, when it solved the group.
    contract: ?ContractStats = null,
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
    /// The recursive group being solved (§8 S3b slice 4), or null.
    group: ?*Group = null,
    /// Per (module, `eq` or `compare`): the module's value of that name,
    /// `none` for no such value, `cmp_unseen` before the first look.
    cmp_decl: []u32 = &.{},
    /// Per declaration, whether its walk is a comparison's (`comparisonWalks`).
    comparison: []bool = &.{},

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
        gpa.free(mod.comparison);
        mod.prepass_arena.deinit();
        mod.base_account.deinit(gpa);
        for (mod.imported_owned.items) |cs| gpa.free(cs);
        mod.imported_owned.deinit(gpa);
        mod.imported.deinit(gpa);
        mod.import_insts.deinit(gpa);
        gpa.free(mod.cmp_decl);
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
            // The read's re-interning is block-sized: a reservation naming no
            // lane, never the first call's `call_view` (§4.1, #1566).
            const kernel = try mod.account.enter(mod.gpa, null);
            defer mod.account.leave(kernel);
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

    /// The `(module, decl)` a callee reference runs: `declOf`, then the
    /// top-level aliases it names followed (R-5.5.6).
    pub fn calleeOfCtx(ctx: *anyopaque, inst: u32) ?[2]u32 {
        const mod = self(ctx);
        return mod.aliasTarget(mod.declOf(inst) orelse return null);
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

    /// The function a called declaration names through top-level aliases
    /// (R-5.5.6, `Prepass.aliasTarget`).
    pub fn aliasTarget(mod: *const Module, t: [2]u32) [2]u32 {
        return Prepass.aliasTarget(mod.in.birs, mod.in.provenance, t);
    }

    /// The `(module, decl)` a call or method call runs, aliases followed.
    fn calledDecl(mod: *const Module, inst: u32) ?[2]u32 {
        const bir = mod.in.bir;
        const t = switch (bir.instTag(@fromBackingInt(inst))) {
            .call => mod.declOf(bir.instData(@fromBackingInt(inst)).lhs),
            .method_call => mod.methodTarget(inst),
            else => null,
        } orelse return null;
        return mod.aliasTarget(t);
    }

    /// The member of the group being solved that `inst`, a `call` or
    /// `method_call`, names, or null.
    fn groupMember(mod: *const Module, inst: u32) ?u32 {
        const g = mod.group orelse return null;
        const t = mod.calledDecl(inst) orelse return null;
        return if (t[0] == mod.in.module) g.index.get(.{t[1]}) else null;
    }

    fn isGroupCall(ctx: *anyopaque, inst: u32) bool {
        return self(ctx).groupMember(inst) != null;
    }

    /// A call of group member `k` (§8 S3b slice 4): its port's class at the
    /// round's generation, read by reference (`Calls.apply`'s view, whose
    /// environment names the class, so views of two generations share no
    /// memo entry), the port's version kept in the walk's read vector: every
    /// part of the class at once, `apply`'s eager reads included (*Ports*,
    /// the coarse rule). Null at another instantiation than the member's own
    /// (polymorphic recursion, S4): the call stays unbuilt, and its group.
    fn groupClass(mod: *Module, g: *Group, k: u32, inst: u32, args: []const u32) Error!?ClassId {
        const own = g.param_places.items[g.param_runs.items[k].start..][0..g.param_runs.items[k].len];
        var same = own.len == args.len and try placeOfInst(mod, inst) == g.result_places.items[k];
        if (same) for (own, args) |p, a| {
            if (try placeOfInst(mod, a) != p) same = false;
        };
        if (!same) {
            if (g.poly == none) g.poly = inst;
            return null;
        }
        const p = g.ports.items[k];
        for (g.reads.items) |x| if (x[0] == k and x[1] == p.version) return p.class;
        try g.reads.append(mod.gpa, .{ k, p.version, p.shape });
        return p.class;
    }

    /// A call a class answered (`Transfer.Context.onCall`): a call of the
    /// group being solved, made by the walk under way, is one of its edges
    /// (§8 S3b slice 4b), kept with the version of its callee's port it saw.
    fn onCall(ctx: *anyopaque, inst: u32, args: []const Walk.Value) Error!void {
        const mod = self(ctx);
        const g = mod.group orelse return;
        if (g.walking == none) return;
        const h = mod.groupMember(inst) orelse return;
        const e = &g.staging;
        const start: u32 = @intCast(e.args.items.len);
        try e.args.appendSlice(mod.gpa, args);
        try e.recs.append(mod.gpa, .{ .callee = h, .inst = inst, .version = g.ports.items[h].version, .args = .{ .start = start, .len = @intCast(args.len) } });
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

    pub fn isListAppend(ctx: *anyopaque, inst: u32) bool {
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
        // A top-level alias is a call of what it names (R-5.5.6).
        const named = target;
        if (target) |t| target = mod.aliasTarget(t);
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
                // A member of the group being solved: its port (§8 S3b slice 4).
                if (t[0] == mod.in.module) if (mod.group) |g| if (g.index.get(.{t[1]})) |k| {
                    return if (try mod.groupClass(g, k, inst, args.items)) |c| .{ .class = c } else .unbuilt;
                };
                // A declaration of this module walked before this one (an
                // earlier group, §8 S3b): its class, applied at this call. One
                // past its limit is not built here.
                if (t[0] == mod.in.module) if (mod.walkedClass(t[1])) |c| return .{ .class = c };
                // An imported alias: the class a module publishes under a name of
                // the chain, which is its target's, a private one too, taken
                // hop by hop: the first name whose module publishes an entry, so
                // a chain through three modules finds one (R-5.5.6).
                if (named) |n0| {
                    var n = n0;
                    var hops: usize = 0;
                    for (mod.in.birs) |b| hops += b.decls.len;
                    while (hops > 0 and !std.mem.eql(u32, &n, &t)) : (hops -= 1) {
                        if (n[0] != mod.in.module) if (try mod.importedClass(n[0], n[1])) |c| return .{ .class = c };
                        n = Prepass.aliasStep(mod.in.birs, mod.in.provenance, n) orelse break;
                    }
                }
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
            var comps: std.ArrayList(Rows.Component) = .empty;
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
        if (di >= mod.result_of.len) return null;
        // An alias of a function, not walked: the class of the function of
        // this module it names (R-5.5.6), which its block publishes under
        // the alias's name, so an importer need not see that function.
        if (mod.result_of[di] == none) {
            const d = mod.in.bir.decls[di];
            if (!Prepass.isAliasShape(mod.in.bir, d) or !isFunctionScheme(mod.in, di)) return null;
            const t = mod.aliasTarget(.{ mod.in.module, di });
            if (t[0] != mod.in.module or t[1] == di or mod.result_of[t[1]] == none) return null;
            return mod.walkedClass(t[1]);
        }
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
    /// `inst` reaches through its first argument's type (§2.13.13), each
    /// with the place of the type that declares it: its derived row calls
    /// each nominal component's own, and a component's own is the whole of
    /// what that type does, so the walk does not go inside it. False when one
    /// has no class an importer or this module may apply.
    fn componentClasses(mod: *Module, root: PlaceId, inst: u32, out: *std.ArrayList(Rows.Component)) Error!bool {
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
        // Another name (a field call, say) names no comparison of a type.
        if (!std.mem.eql(u8, name, "eq") and !std.mem.eql(u8, name, "compare")) return true;
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
                if (!mod.in.isCore(m)) if (try mod.userComparison(interner, m, name)) |di| {
                    const c = (if (m == mod.in.module) mod.walkedClass(di) else try mod.importedClass(m, di)) orelse return false;
                    try out.append(mod.gpa, .{ .place = p, .class = c });
                    continue;
                };
            }
            try stack.appendSlice(mod.gpa, mod.places.steps(p).children);
        }
        return true;
    }

    /// The value `name` (`eq` or `compare`) of module `m`, pub or not: a type's
    /// method is a value of the module that declares it, and a private one still
    /// answers dispatch inside that module, through a derived row too (§2.13.13).
    /// Found once per module and name, then remembered.
    fn userComparison(mod: *Module, interner: *const InternPool.Global, m: u32, name: []const u8) Allocator.Error!?u32 {
        const slot: usize = if (std.mem.eql(u8, name, "eq")) 0 else if (std.mem.eql(u8, name, "compare")) 1 else 1;
        if (mod.cmp_decl.len == 0) {
            mod.cmp_decl = try mod.gpa.alloc(u32, mod.in.birs.len * 2);
            @memset(mod.cmp_decl, cmp_unseen);
        }
        const at = m * 2 + slot;
        if (mod.cmp_decl[at] == cmp_unseen) {
            const bir = mod.in.birs[m];
            mod.cmp_decl[at] = none;
            for (bir.decls, 0..) |d, di| {
                if (d.kind != .value) continue;
                if (std.mem.eql(u8, interner.slice(bir.symbol(d.name)), name)) {
                    mod.cmp_decl[at] = @intCast(di);
                    break;
                }
            }
        }
        const got = mod.cmp_decl[at];
        return if (got == none) null else got;
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
            .onCall = onCall,
        };
    }
};

/// Check every declaration of a module (§8 S3a): a worded one is its row,
/// any other value with a body is walked, in the pre-pass's group order; a
/// recursive group is solved whole (§8 S3b slice 4, `solveGroup`).
/// The module owns its answer. A group the summary-size limit stops
/// is checked again alone, in fresh tables, and refused only if that cold
/// run is stopped too (§4.4, #1104): the module's shared tables charge a
/// first miss to whoever meets it, so a warm account depends on where the
/// declaration sits, a cold one never. Its accounts are then the cold run's;
/// `cold_accounts` (the dump's) makes every declaration's so.
pub fn checkModule(in: *const Input, mod: *Module, cold_accounts: bool) Allocator.Error!void {
    const gpa = in.gpa;
    try initModule(in, mod);
    const prepass = try Prepass.run(gpa, mod.prepass_arena.allocator(), .{ .bir = in.bir, .dispatch = in.dispatch });
    var pool: ColdPool = .{};
    defer pool.deinit(gpa);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    for (0..prepass.starts.len - 1) |gi| {
        try groupMembers(gpa, in, &prepass, gi, null, &members);
        if (members.items.len == 0) continue;
        const start = mod.results.items.len;
        for (members.items) |di| {
            try mod.results.append(gpa, .{ .decl = di, .account = .{ .allowance = allowanceOf(in.bir, di) } });
            mod.result_of[di] = @intCast(mod.results.items.len - 1);
        }
        const rs = mod.results.items[start..];
        try solve(mod, members.items, prepass.recursive[gi], &prepass, rs);
        var stopped = false;
        for (rs) |r| stopped = stopped or (r.failure != null and r.failure.? == .exhausted);
        if (!stopped and !cold_accounts) continue;
        const colds = try gpa.alloc(DeclResult, rs.len);
        for (colds, members.items) |*c, di| c.* = .{ .decl = di, .account = .{ .allowance = allowanceOf(in.bir, di) } };
        defer {
            for (colds) |*c| c.account.deinit(gpa);
            gpa.free(colds);
        }
        try coldRun(mod, &pool, members.items, prepass.recursive[gi], &prepass, colds);
        var cold_failed = false;
        for (colds) |c| cold_failed = cold_failed or c.failure != null;
        if (stopped and !cold_failed) {
            // Within the limit alone: solved again here, unbounded, for its
            // classes and lines in this module's tables.
            for (rs, members.items) |*r, di| {
                gpa.free(r.lines);
                r.account.deinit(gpa);
                r.* = .{ .decl = di, .account = .{ .allowance = std.math.maxInt(u32) - 1 } };
            }
            try solve(mod, members.items, prepass.recursive[gi], &prepass, rs);
        }
        for (rs, colds) |*r, *c| {
            r.account.deinit(gpa);
            r.account = c.account;
            c.account = .{};
            if (!stopped) continue;
            // Refused cold too: the cold run's answer, whole (a group fails whole).
            r.failure = c.failure;
            if (!cold_failed) continue;
            r.unbuilt = c.unbuilt;
            r.polymorphic = c.polymorphic;
            r.class = .none;
            gpa.free(r.lines);
            r.lines = &.{};
        }
    }
    mod.account = &mod.base_account;
    mod.adapter.account = &mod.base_account;
}

/// Whether declaration `di` is walked: a value with a body and no words,
/// and no alias of a function, which is checked at its calls (R-5.5.6:
/// a call of it is a call of what it names, `Module.aliasTarget`).
fn isWalked(in: *const Input, di: u32) bool {
    const bir = in.bir;
    const d = bir.decls[di];
    if (d.kind != .value or d.body == .none or bir.ownSlotsV2(d).len != 0) return false;
    if (!(Prepass.isAliasShape(bir, d) and isFunctionScheme(in, di))) return true;
    // A comparison naming another module's function: walked, and unbuilt at
    // the name, since that module walked it as no comparison (R-5.13.1).
    return isComparisonDecl(in, di) and Prepass.aliasTarget(in.birs, in.provenance, .{ in.module, di })[0] != in.module;
}

/// Whether declaration `di`'s scheme is a function's.
fn isFunctionScheme(in: *const Input, di: u32) bool {
    if (di >= in.decl_scheme.len) return false;
    const v = in.decl_scheme[di].unwrap() orelse return false;
    return switch (in.store.resolvedContent(v)) {
        .structure => |s| s == .func,
        else => false,
    };
}

/// R_f (§4.4): the declaration's `@ownership_summary_size`, else the
/// module's, else the default.
fn allowanceOf(bir: *const Bir, di: u32) u32 {
    const d = bir.decls[di];
    return if (d.summary_size != 0) d.summary_size else if (bir.summary_size != 0) bir.summary_size else Ids.Account.default_allowance;
}

/// Group `gi`'s walked declarations not yet in `skip`, by name (§3.8).
fn groupMembers(gpa: Allocator, in: *const Input, prepass: *const Facts.Prepass, gi: usize, skip: ?[]const bool, out: *std.ArrayList(u32)) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (prepass.order[prepass.starts[gi]..prepass.starts[gi + 1]]) |di| {
        if (isWalked(in, di) and (skip == null or !skip.?[di])) try out.append(gpa, di);
    }
    // By name, not position (§3.8): the first walked pays a shared memo's miss.
    std.mem.sort(u32, out.items, in, struct {
        fn lessThan(x: *const Input, a: u32, b: u32) bool {
            return nameRank(x, a) < nameRank(x, b);
        }
    }.lessThan);
}

fn nameRank(in: *const Input, di: u32) u32 {
    const s = @backingInt(in.bir.symbol(in.bir.decls[di].name));
    return if (s < in.ranks.len) in.ranks[s] else s;
}

/// A group's declarations walked into `rs`: one walk, or a recursive group
/// solved whole.
fn solve(mod: *Module, members: []const u32, recursive: bool, prepass: *const Facts.Prepass, rs: []DeclResult) Allocator.Error!void {
    if (!recursive) {
        for (members, rs, 0..) |di, *r, k| {
            // Stage 5 (a diagnostic variant): a first-order function outside
            // any recursive group is summarised by its contract too.
            if ((mod.in.contracts == 5 or mod.in.contracts == 7 or mod.in.contracts == 8) and mod.in.bir.decls[di].params != 0) {
                try solveGroup(mod, members[k..][0..1], prepass, rs[k..][0..1]);
                continue;
            }
            try walkIn(mod, mod.in.bir.decls[di], prepass, r);
        }
        return;
    }
    try solveGroup(mod, members, prepass, rs);
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

/// Group `ds` solved cold on `colds`' accounts, after every group earlier
/// than it that it reaches by calls (`.top` references and dispatched
/// method calls), each solved whole. A callee group the warm run stopped at
/// a limit, or left unbuilt, is not walked: the cold run applies no class
/// for it either.
fn coldRun(mod: *Module, pool: *ColdPool, ds: []const u32, recursive: bool, prepass: *const Facts.Prepass, colds: []DeclResult) Allocator.Error!void {
    const gpa = mod.gpa;
    const in = mod.in;
    const bir = in.bir;
    const g0 = prepass.group_of[ds[0]];
    const reached = try gpa.alloc(bool, bir.decls.len);
    defer gpa.free(reached);
    @memset(reached, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, ds);
    while (stack.pop()) |x| {
        const d = bir.decls[x];
        for (d.inst_start.int()..d.inst_end.int()) |i| {
            const md = mod.declOf(@intCast(i)) orelse continue;
            const t = md[1];
            if (md[0] != in.module or t >= bir.decls.len or reached[t] or prepass.group_of[t] >= g0) continue;
            // A member of a recursive group reaches the whole group.
            const gt = prepass.group_of[t];
            for (prepass.order[prepass.starts[gt]..prepass.starts[gt + 1]]) |y| if (!reached[y]) {
                reached[y] = true;
                try stack.append(gpa, y);
            };
        }
    }
    // Reuse the pool only when everything it holds is a callee of `ds`.
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
    var ms: std.ArrayList(u32) = .empty;
    defer ms.deinit(gpa);
    for (0..g0) |gi| {
        const first = prepass.order[prepass.starts[gi]];
        if (!reached[first]) continue;
        try groupMembers(gpa, in, prepass, gi, pool.walked, &ms);
        for (prepass.order[prepass.starts[gi]..prepass.starts[gi + 1]]) |x| pool.walked[x] = true;
        if (ms.items.len == 0) continue;
        const start = alone.results.items.len;
        var copied = false;
        for (ms.items) |x| {
            const warm = mod.results.items[mod.result_of[x]];
            copied = copied or warm.failure != null or warm.unbuilt != none;
            try alone.results.append(gpa, .{ .decl = x, .account = .{ .allowance = warm.account.allowance } });
            alone.result_of[x] = @intCast(alone.results.items.len - 1);
        }
        const rs = alone.results.items[start..];
        if (copied) {
            for (ms.items, rs) |x, *r| {
                const warm = mod.results.items[mod.result_of[x]];
                r.failure = warm.failure;
                r.unbuilt = warm.unbuilt;
                r.polymorphic = warm.polymorphic;
            }
            continue;
        }
        try solve(alone, ms.items, prepass.recursive[gi], prepass, rs);
    }
    try solve(alone, ds, recursive, prepass, colds);
    // `ds` itself, for the next cold run that calls it.
    for (ds, colds) |di, *c| {
        gpa.free(c.lines);
        c.lines = &.{};
        pool.walked[di] = true;
        try alone.results.append(gpa, .{ .decl = di, .class = c.class, .unbuilt = c.unbuilt, .polymorphic = c.polymorphic, .failure = c.failure });
        alone.result_of[di] = @intCast(alone.results.items.len - 1);
    }
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
    mod.conds.order_check = in.order_check;
    mod.conds.propagate_dump = in.propagate_dump;
    mod.conds.resolver = mod.views.resolver();
    mod.conds.hyp = mod.views.hyp();
    mod.shapes.trackRelevance();
    mod.result_of = try in.gpa.alloc(u32, in.bir.decls.len);
    @memset(mod.result_of, none);
    mod.comparison = try comparisonWalks(in);
}

/// `mod` charging `account` from here on.
fn charging(mod: *Module, account: *Ids.Account) void {
    mod.account = account;
    mod.adapter.account = account;
}

/// Walk `d` in `mod`'s tables on `r`'s account; a limit is `r`'s failure.
fn walkIn(mod: *Module, d: Bir.Decl, prepass: *const Facts.Prepass, r: *DeclResult) Allocator.Error!void {
    charging(mod, &r.account);
    mod.cur_locals = d.locals_start;
    walkOne(mod, d, prepass, r) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnershipLimit, error.AccountingInvariant => r.failure = r.account.failed,
    };
}

/// The places of `d`'s parameters, appended to `out`, and of its result.
/// The parameters' places are the scheme's: a pattern parameter (a tuple,
/// a record, a constructor) has no type of its own.
fn declPlaces(mod: *Module, d: Bir.Decl, di: u32, out: *std.ArrayList(PlaceId)) Error!PlaceId {
    const gpa = mod.gpa;
    const start = out.items.len;
    const params = mod.in.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index);
    const scheme: Var.Optional = if (di < mod.in.decl_scheme.len) mod.in.decl_scheme[di] else .none;
    if (scheme.unwrap()) |v| switch (mod.in.store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .func => |f| if (mod.in.store.vars(f.params).len == params.len) for (mod.in.store.vars(f.params)) |p| try out.append(gpa, try mod.adapter.placeOfVar(p.toOptional())),
            else => {},
        },
        else => {},
    };
    if (out.items.len - start != params.len) {
        out.shrinkRetainingCapacity(start);
        for (params) |p| {
            const b = mod.in.bir;
            const at = if (b.instTag(p) == .pat_var) try Module.placeOfLocal(mod, b.instData(p).lhs) else try Module.placeOfInst(mod, p.int());
            try out.append(gpa, at);
        }
    }
    return Module.placeOfInst(mod, d.body.unwrap().?.int());
}

/// Whether declaration `di` is a type's `eq` or `compare` (§2.13.13 item
/// 13, R-5.13.1), by the checker's own test of a well-known method
/// (`Instances.writtenFor`, `fitsWellKnown`): the module's value of that
/// name, `pub` or not (a private one answers `==` and `<` inside its
/// module), whose scheme is `T …, T … → Bool` (`Order` for `compare`) for
/// a type `T` the module declares. An alias of a function is one too.
fn isComparisonDecl(in: *const Input, di: u32) bool {
    const d = in.bir.decls[di];
    if (d.kind != .value or di >= in.decl_scheme.len) return false;
    const name = in.bir.symbol(d.name);
    const is_eq = name == InternPool.WellKnown.eq.symbol();
    if (!is_eq and name != InternPool.WellKnown.compare.symbol()) return false;
    const f = switch (in.store.resolvedContent(in.decl_scheme[di].unwrap() orelse return false)) {
        .structure => |s| switch (s) {
            .func => |f| f,
            else => return false,
        },
        else => return false,
    };
    // `fitsWellKnown`'s shape: two parameters, each a variable (flex, rigid,
    // `err`) or an application of the type, and a variable or the well-known
    // result. The type is the one the applications name, a type of this
    // module; with none, `==` may call it on any type the module declares.
    const params = in.store.vars(f.params);
    if (params.len != 2) return false;
    var t: Types.TypeId = .none;
    for (params) |p| switch (in.store.resolvedContent(p)) {
        .flex, .rigid, .err => {},
        .structure => |s| switch (s) {
            .app => |a| {
                if (t != .none and a.type != t) return false;
                t = a.type;
            },
            else => return false,
        },
        .alias => return false,
    };
    if (t == .none) {
        var any = false;
        for (in.types.entries) |e| any = any or (e.module.int() == in.module and e.kind != .alias);
        if (!any) return false;
    } else if (t.int() >= in.types.entries.len or in.types.entries[t.int()].module.int() != in.module) return false;
    return switch (in.store.resolvedContent(f.result)) {
        .flex, .rigid, .err => true,
        .structure => |s| switch (s) {
            .app => |a| a.args.len == 0 and a.type == if (is_eq) in.types.well_known.bool else in.types.well_known.order,
            else => false,
        },
        .alias => false,
    };
}

/// Per declaration of the module, whether its walk is a comparison's: a
/// type's `eq` or `compare`, or the declaration of this module a
/// comparison names through aliases (`compare = helper`: `helper`'s
/// writes are the comparison's, refused at the write). A comparison
/// that names another module's function is walked itself, and stays
/// unbuilt at the name (`isWalked`).
fn comparisonWalks(in: *const Input) Allocator.Error![]bool {
    const out = try in.gpa.alloc(bool, in.bir.decls.len);
    @memset(out, false);
    for (0..in.bir.decls.len) |di| {
        if (!isComparisonDecl(in, @intCast(di))) continue;
        const t = Prepass.aliasTarget(in.birs, in.provenance, .{ in.module, @intCast(di) });
        if (t[0] == in.module) out[t[1]] = true;
    }
    return out;
}
fn walkOne(mod: *Module, d: Bir.Decl, prepass: *const Facts.Prepass, r: *DeclResult) Error!void {
    const gpa = mod.gpa;
    // S_f (§4.1): the written instructions, the source this owner's
    // baseline is proportional to (instrumentation, §4.4).
    r.account.source = d.inst_end.int() - d.inst_start.int();
    var param_places: std.ArrayList(PlaceId) = .empty;
    defer param_places.deinit(gpa);
    const result_place = try declPlaces(mod, d, r.decl, &param_places);
    var res = try Walk.walk(.{
        .env = mod.env(),
        .sums = &mod.sums,
        .ctx = mod.context(),
        .bir = mod.in.bir,
        .decl = d,
        .prepass = prepass,
        .param_places = param_places.items,
        .result_place = result_place,
        .comparison = mod.comparison[r.decl],
    });
    r.class = res.class;
    r.unbuilt = res.unbuilt;
    r.lines = res.lines;
    res.lines = &.{};
}

// ---------------------------------------------------------------------------
// Recursive groups (§8 S3b slice 4)
// ---------------------------------------------------------------------------

/// A port (§2.12 *Settled generation*): a member's class for the current
/// round, immutable, and its version, which moves only when the class does.
/// `shape` is the version of its `res.shape` (§8 S3b slice 4, *Ports*): it
/// moves only when a path of `res` holds a cell where no path held one at
/// its last move (`shape_res`), and only it wakes an inference walk.
const Port = struct { class: ClassId, version: u32, shape: u32 = 0, shape_res: Ids.NodeId };

/// A group call one walk of a member made (§8 S3b slice 4b): the callee,
/// the version of its port the edge has (the call's, then each
/// delivery's), and its arguments, its argument edges. `tail`: the call is
/// in tail position, so its answer is the caller's value whole, its result
/// edge.
const Rec = struct { callee: u32, inst: u32, version: u32, args: Ids.Range, tail: bool = false };

/// One walk's group calls.
const Edges = struct {
    recs: std.ArrayList(Rec) = .empty,
    args: std.ArrayList(Walk.Value) = .empty,

    fn clear(e: *Edges) void {
        e.recs.clearRetainingCapacity();
        e.args.clearRetainingCapacity();
    }

    fn deinit(e: *Edges, gpa: Allocator) void {
        e.recs.deinit(gpa);
        e.args.deinit(gpa);
    }

    fn argsOf(e: *const Edges, r: Rec) []const Walk.Value {
        return e.args.items[r.args.start..][0..r.args.len];
    }
};

/// The recursive group being solved: its ports, and per member its places,
/// stable labels, walk count, and its last walk's lines, class, read
/// vector and edges. It is the group's scratch: nothing here reaches
/// `results` until the group settles.
const Group = struct {
    gpa: Allocator,
    members: []const u32,
    /// Declaration → member.
    index: Ids.FixedDict(1) = .{},
    ports: std.ArrayList(Port) = .empty,
    param_runs: std.ArrayList(Ids.Range) = .empty,
    param_places: std.ArrayList(PlaceId) = .empty,
    result_places: std.ArrayList(PlaceId) = .empty,
    fresh: []Ids.FixedDict(3) = &.{},
    walks: []u32 = &.{},
    /// Per member, its walks the wake rule woke (round 1's included).
    inference: []u32 = &.{},
    /// Per member, the `(edge, delta)` deliveries it received.
    deliveries: []u32 = &.{},
    lines: [][]Walk.Line = &.{},
    out: []ClassId = &.{},
    /// Per member, its last walk's read vector: a run of `vec_store`.
    vectors: []Ids.Range = &.{},
    vec_store: std.ArrayList([3]u32) = .empty,
    /// The read vector of the walk under way: `(member, version, shape)`.
    reads: std.ArrayList([3]u32) = .empty,
    /// Per member, its last walk's edges; `staging`, the walk's under way.
    edges: []Edges = &.{},
    staging: Edges = .{},
    /// The member being walked, `none` between walks.
    walking: u32 = none,
    /// The members whose port moved, to carry along their edges.
    queue: std.ArrayList(u32) = .empty,
    queued: []bool = &.{},
    /// Per member, the edges of which it is the callee: `(caller, call)`.
    callers: []std.ArrayList([2]u32) = &.{},
    scratch: Calls.Scratch = .{},
    /// The first group call at another instantiation than its member's own.
    poly: u32 = none,

    fn deinit(g: *Group, gpa: Allocator) void {
        g.index.deinit(gpa);
        g.ports.deinit(gpa);
        g.param_runs.deinit(gpa);
        g.param_places.deinit(gpa);
        g.result_places.deinit(gpa);
        for (g.fresh) |*f| f.deinit(gpa);
        gpa.free(g.fresh);
        gpa.free(g.walks);
        gpa.free(g.inference);
        gpa.free(g.deliveries);
        for (g.lines) |l| gpa.free(l);
        gpa.free(g.lines);
        gpa.free(g.out);
        gpa.free(g.vectors);
        g.vec_store.deinit(gpa);
        g.reads.deinit(gpa);
        for (g.edges) |*e| e.deinit(gpa);
        gpa.free(g.edges);
        g.staging.deinit(gpa);
        g.queue.deinit(gpa);
        gpa.free(g.queued);
        for (g.callers) |*c| c.deinit(gpa);
        gpa.free(g.callers);
        g.scratch.deinit(gpa);
    }

    /// Whether member `k`'s last walk read a version that has moved: the
    /// read check (*Validation*).
    fn stale(g: *const Group, k: usize) bool {
        const v = g.vectors[k];
        for (g.vec_store.items[v.start..][0..v.len]) |x| if (g.ports.items[x[0]].version != x[1]) return true;
        return false;
    }

    /// Whether member `k`'s last walk read a `res.shape` that has moved:
    /// the wake rule (*Ports*).
    fn woken(g: *const Group, k: usize) bool {
        const v = g.vectors[k];
        for (g.vec_store.items[v.start..][0..v.len]) |x| if (g.ports.items[x[0]].shape != x[2]) return true;
        return false;
    }

    /// Whether `class` is a member's port, as the walk under way reads it.
    fn isPort(ctx: *anyopaque, class: ClassId) bool {
        const g: *Group = @ptrCast(@alignCast(ctx));
        for (g.ports.items) |p| if (p.class == class) return true;
        return false;
    }

    fn enqueue(g: *Group, k: u32) Allocator.Error!void {
        if (g.queued[k]) return;
        g.queued[k] = true;
        try g.queue.append(g.gpa, k);
    }

    fn receiver(g: *Group, mod: *Module, k: u32) Walk.Receiver {
        const run = g.param_runs.items[k];
        return .{
            .env = mod.env(),
            .sums = &mod.sums,
            .param_places = g.param_places.items[run.start..][0..run.len],
            .result_place = g.result_places.items[k],
            .labels = .{ .fresh = &g.fresh[k], .ctx = mod, .group_call = Module.isGroupCall },
        };
    }
};

/// Solve a recursive group (§8 S3b slice 4): every port from ⊥, then
/// synchronous rounds. A round walks every member the last one woke
/// (round 1: all), each against the ports as the round began, in text
/// order, which fixes ids only; each walked member's port takes
/// `widen(x ⊔ F(x))` where its read-off is not below it (`Summary.leq`,
/// coinductive), and `propagate` then carries the facts along the group's
/// edges to quiescence (4b). Only a callee's new `res.shape` wakes a walk
/// (the wake rule); every other fact is delivered. When nothing wakes, the
/// read check walks again every member whose last walk read a version that
/// has moved, and the loop stops at the joint fixpoint: every member's
/// last walk read the ports as they stand, and its read-off is below its
/// port. That walk is its validation: its lines are the ones reported, and
/// every member publishes at once. A group is built whole or not at all:
/// a member's walk unbuilt, or a limit anywhere, publishes nothing for any
/// member.
fn solveGroup(mod: *Module, members: []const u32, prepass: *const Facts.Prepass, rs: []DeclResult) Allocator.Error!void {
    const gpa = mod.gpa;
    var g: Group = .{ .gpa = gpa, .members = members };
    defer g.deinit(gpa);
    mod.group = &g;
    // A view of a member's port is a hypothesis node (#1485).
    mod.views.group = .{ .ctx = &g, .isPort = Group.isPort };
    // Widen opens a join on a cycle place in a group's rounds (#1363).
    mod.shapes.widen_rounds = true;
    defer {
        mod.shapes.widen_rounds = false;
        mod.group = null;
        mod.views.group = null;
        charging(mod, &mod.base_account);
    }
    const use_contract = mod.in.contracts != 0 and (contractScope(mod, members) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnershipLimit, error.AccountingInvariant => false,
    });
    const settled = (if (use_contract) runContractGroup(mod, &g, prepass, rs) else runGroup(mod, &g, prepass, rs)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OwnershipLimit, error.AccountingInvariant => false,
    };
    if (settled) return;
    // No member publishes a class it earned: an unbuilt one has the
    // pessimistic class, as an unbuilt walk does, on the module's account.
    charging(mod, &mod.base_account);
    var places: std.ArrayList(PlaceId) = .empty;
    defer places.deinit(gpa);
    for (rs, members) |*r, di| {
        if (r.account.failed) |f| r.failure = f;
        gpa.free(r.lines);
        r.lines = &.{};
        r.class = .none;
        if (r.failure != null) continue;
        // Every other member is unbuilt at its first group call.
        const d = mod.in.bir.decls[di];
        if (r.unbuilt == none) r.unbuilt = firstGroupCall(mod, d);
        places.clearRetainingCapacity();
        mod.cur_locals = d.locals_start;
        r.class = pessimisticOf(mod, d, di, &places) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OwnershipLimit, error.AccountingInvariant => blk: {
                r.failure = mod.base_account.failed;
                break :blk .none;
            },
        };
    }
}

fn runGroup(mod: *Module, g: *Group, prepass: *const Facts.Prepass, rs: []DeclResult) Error!bool {
    const gpa = mod.gpa;
    const n = g.members.len;
    g.fresh = try gpa.alloc(Ids.FixedDict(3), n);
    @memset(g.fresh, .{});
    g.walks = try gpa.alloc(u32, n);
    @memset(g.walks, 0);
    g.inference = try gpa.alloc(u32, n);
    @memset(g.inference, 0);
    g.deliveries = try gpa.alloc(u32, n);
    @memset(g.deliveries, 0);
    g.lines = try gpa.alloc([]Walk.Line, n);
    @memset(g.lines, &.{});
    g.out = try gpa.alloc(ClassId, n);
    g.vectors = try gpa.alloc(Ids.Range, n);
    @memset(g.vectors, .{ .start = 0, .len = 0 });
    g.edges = try gpa.alloc(Edges, n);
    @memset(g.edges, .{});
    g.queued = try gpa.alloc(bool, n);
    @memset(g.queued, false);
    g.callers = try gpa.alloc(std.ArrayList([2]u32), n);
    @memset(g.callers, .empty);
    const which = try gpa.alloc(bool, n);
    defer gpa.free(which);
    @memset(which, true);
    // ⊥: no marks, `res` nothing, no κ, `xreq` yes (§2.12 *Recursive proofs*).
    for (g.members, 0..) |di, k| {
        (try g.index.getOrPut(gpa, .{di})).value_ptr.* = @intCast(k);
        const d = mod.in.bir.decls[di];
        charging(mod, &rs[k].account);
        rs[k].account.source = d.inst_end.int() - d.inst_start.int();
        mod.cur_locals = d.locals_start;
        const start: u32 = @intCast(g.param_places.items.len);
        const res = try declPlaces(mod, d, di, &g.param_places);
        try g.param_runs.append(gpa, .{ .start = start, .len = @intCast(g.param_places.items.len - start) });
        try g.result_places.append(gpa, res);
        const uses = try gpa.alloc(Ids.NodeId, g.param_places.items.len - start);
        defer gpa.free(uses);
        @memset(uses, .none);
        const nothing = try mod.shapes.nothing(gpa, mod.account, res);
        try g.ports.append(gpa, .{ .class = try mod.sums.add(mod.env(), .{ .params = uses, .res = nothing }), .version = 0, .shape_res = nothing });
    }
    var inference = true;
    while (true) {
        if (!try pass(mod, g, prepass, rs, which, inference)) return false;
        // A test-only mutation: stop after the first pass, before the
        // fixpoint, so the induction's check must fire (C5).
        if (mutated("cert-stop-early")) break;
        // The wake rule: a callee's new `res.shape` wakes an inference walk.
        var any = false;
        for (which, 0..) |*w, k| {
            w.* = g.woken(k);
            any = any or w.*;
        }
        inference = any;
        if (any) continue;
        // The read check: a walk whose read vector moved is walked again,
        // against the ports as they stand (*Validation*).
        for (which, 0..) |*w, k| {
            w.* = g.stale(k);
            any = any or w.*;
        }
        if (!any) break;
    }
    // Re-walks leave table state that later callers read, so they run only
    // under the test-only flag and the cross-check build, never in a
    // counted run (#1582, #1525).
    if (mod.in.rewalk_check or (std.debug.runtime_safety and full_cross_check)) {
        try assertRewalks(mod, g, prepass);
        try checkInduction(mod, g, prepass);
    }
    for (rs, 0..) |*r, k| {
        charging(mod, &r.account);
        // Its stable labels: `map` would drop a κ keyed below a choice (#1399).
        r.class = g.ports.items[k].class;
        // The joint fixpoint proves the certificates: every member's last
        // walk read the ports as they stand, its hypothesis nodes their
        // certificates, and its read-off is below its port, so F(A) ⊑ A,
        // and the base is in F (§8 slice 4, *The proof is the stop rule's*).
        try mod.sums.certify(gpa, r.class);
        r.walks = g.walks[k];
        r.inference = g.inference[k];
        r.deliveries = g.deliveries[k];
        r.lines = g.lines[k];
        g.lines[k] = &.{};
    }
    return true;
}

/// At the joint fixpoint, each member walked once more against the ports
/// as they stand reads off its last walk's class, both ways `Summary.leq`
/// (§8 S3b slice 4, *Validation and publication*: the stop rule takes a
/// walk to be a function of the ports, #1582), under the hidden
/// `--ownership-rewalk-check`, which the corpus passes to every v2 dump.
/// The walk is a validation walk on an account of its own, with no member
/// under way, so it moves no limit, count or edge; it warms memos, so a
/// counted test never passes the flag (#1525).
fn assertRewalks(mod: *Module, g: *Group, prepass: *const Facts.Prepass) Error!void {
    const gpa = mod.gpa;
    for (g.members, 0..) |di, k| {
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa);
        charging(mod, &scratch);
        const d = mod.in.bir.decls[di];
        mod.cur_locals = d.locals_start;
        scratch.source = d.inst_end.int() - d.inst_start.int();
        g.reads.clearRetainingCapacity();
        const run = g.param_runs.items[k];
        var again = try Walk.walk(.{
            .env = mod.env(),
            .sums = &mod.sums,
            .ctx = mod.context(),
            .bir = mod.in.bir,
            .decl = d,
            .prepass = prepass,
            .phase = .validation,
            .param_places = g.param_places.items[run.start..][0..run.len],
            .result_place = g.result_places.items[k],
            .labels = .{ .fresh = &g.fresh[k], .ctx = mod, .group_call = Module.isGroupCall },
            .comparison = mod.comparison[di],
        });
        defer again.deinit(gpa);
        if (again.unbuilt != none) std.debug.panic("ownership v2: a recursive member walked again at the fixpoint is unbuilt (#1582)", .{});
        const env = mod.env();
        if (!try mod.sums.leq(env, again.class, g.out[k]) or !try mod.sums.leq(env, g.out[k], again.class))
            std.debug.panic("ownership v2: a recursive member walked again against the same ports reads off another class (§8 S3b slice 4, #1582)", .{});
    }
}

/// One pass (§8 S3b slice 4): the members `which` walked against the ports
/// as they stand, each walk's read-off joined into its port, the new
/// edges given the facts already present, and `propagate` run to
/// quiescence. False when a walk is unbuilt: the group is.
fn pass(mod: *Module, g: *Group, prepass: *const Facts.Prepass, rs: []DeclResult, which: []const bool, inference: bool) Error!bool {
    const gpa = mod.gpa;
    for (g.members, 0..) |_, k| if (which[k]) {
        g.staging.clear();
        g.walking = @intCast(k);
        var res = walkMember(mod, g, @intCast(k), prepass, &rs[k]) catch |err| {
            g.walking = none;
            return err;
        };
        g.walking = none;
        if (res.unbuilt != none) {
            res.deinit(gpa);
            rs[k].unbuilt = res.unbuilt;
            rs[k].polymorphic = res.unbuilt == g.poly;
            return false;
        }
        if (inference) g.inference[k] += 1;
        if (contract_trace) std.debug.print("v2 walk {d} member {d}: growth {d} total {d}\n", .{ g.walks[k], k, rs[k].account.growth, rs[k].account.total() });
        gpa.free(g.lines[k]);
        g.lines[k] = res.lines;
        g.out[k] = res.class;
        g.vectors[k] = .{ .start = @intCast(g.vec_store.items.len), .len = @intCast(g.reads.items.len) };
        try g.vec_store.appendSlice(gpa, g.reads.items);
        std.mem.swap(Edges, &g.edges[k], &g.staging);
        try tailCalls(mod, &g.edges[k], mod.in.bir.decls[g.members[k]]);
    };
    for (g.callers) |*c| c.clearRetainingCapacity();
    for (g.edges, 0..) |e, k| for (e.recs.items, 0..) |r, ri| try g.callers[r.callee].append(gpa, .{ @intCast(k), @intCast(ri) });
    // The pass's joins, each charged to the member that receives it (Q2).
    for (g.members, 0..) |_, k| if (which[k]) {
        charging(mod, &rs[k].account);
        const p = &g.ports.items[k];
        if (try mod.sums.leq(mod.env(), g.out[k], p.class)) continue;
        p.class = try mod.sums.join(mod.env(), p.class, g.out[k], .choice);
        p.version += 1;
        try g.enqueue(@intCast(k));
    };
    // A new edge receives the facts already present once (§2.12
    // *Termination*): its callee's class, where it moved past the walk's.
    for (g.members, 0..) |_, k| if (which[k]) {
        for (g.edges[k].recs.items, 0..) |_, ri| try deliver(mod, g, rs, @intCast(k), @intCast(ri));
    };
    try propagate(mod, g, rs);
    for (g.ports.items, 0..) |*p, k| {
        charging(mod, &rs[k].account);
        try shapeMove(mod, p);
    }
    return true;
}

/// `Fix.propagate` (§8 S3b slice 4b): each member whose port moved, in
/// the order they moved, has its class carried along every edge of which
/// it is the callee, in member and call order; a delivery that moves its
/// receiver's port queues the receiver. An edge receives each version of
/// its callee's class once. Marks go backwards along argument edges, and
/// cells with their κ forwards along a tail call's result edge; a
/// delivered fact wakes no walk. The ports only rise in finite lattices
/// (*Termination*), and every delivery is the receiver's growth, so the
/// queue empties or a limit stops the group.
///
/// The class delivered is the callee's whole port, never the part that
/// moved: an image of a join is not the join of the images where κ and
/// the widening's folds are concerned (§2.9), so a delta delivered alone
/// would make a class the walks do not, and the joint fixpoint another.
/// A projection of a call's answer carries no result edge (*As built,
/// 4b*): its image put alone at its path is a partial alternative whose κ
/// the walk's value does not have, so the read check walks for it.
fn propagate(mod: *Module, g: *Group, rs: []DeclResult) Error!void {
    var i: usize = 0;
    while (i < g.queue.items.len) : (i += 1) {
        const h = g.queue.items[i];
        g.queued[h] = false;
        for (g.callers[h].items) |c| try deliver(mod, g, rs, c[0], c[1]);
    }
    g.queue.clearRetainingCapacity();
}

/// The class of the callee of call `ri` of member `f`'s last walk along
/// that call's edges, unless the edge has it already: its uses' marks onto
/// the arguments' parameter parts (`Walk.argumentMarks`), and at a tail
/// call its `res` applied over the arguments (`Calls.apply`, the call's
/// own instantiation and label, so its fresh cells are `ι⋆`), read off as
/// `f`'s walk reads its value off (`Walk.delivered`). Joined into `f`'s
/// port when not below it.
fn deliver(mod: *Module, g: *Group, rs: []DeclResult, f: u32, ri: u32) Error!void {
    const gpa = mod.gpa;
    const e = &g.edges[f];
    const r = &e.recs.items[ri];
    const callee = g.ports.items[r.callee];
    if (callee.version == r.version) return;
    r.version = callee.version;
    const d = callee.class;
    charging(mod, &rs[f].account);
    const env = mod.env();
    try env.charge.reserve(gpa, .task, 1);
    g.deliveries[f] += 1;
    const recv = g.receiver(mod, f);
    const uses = try gpa.alloc(Ids.NodeId, recv.param_places.len);
    defer gpa.free(uses);
    @memset(uses, .none);
    const du = mod.sums.paramUses(d);
    const args = e.argsOf(r.*);
    for (args, 0..) |a, k| if (k < du.len) try Walk.argumentMarks(recv, uses, du[k], a);
    var result: ?Walk.Value = null;
    if (r.tail) {
        g.scratch.result_place = try Module.placeOfInst(mod, r.inst);
        var v = (try Calls.apply(env, &mod.sums, d, args, r.inst, &g.scratch)).result;
        if (v.node != .none and mod.shapes.place(v.node) != recv.result_place) v.node = try mod.shapes.recast(gpa, env.account(), recv.result_place, v.node);
        result = v;
    }
    const delta = try Walk.delivered(recv, uses, result);
    const p = &g.ports.items[f];
    if (try mod.sums.leq(env, delta, p.class)) return;
    p.class = try mod.sums.join(env, p.class, delta, .choice);
    p.version += 1;
    try g.enqueue(f);
}

/// Marks the calls of a walk in tail position (§8 S3b slice 4b, *result
/// edges*): the body's value through `let`s and arms, so the call's answer
/// is the caller's value whole, whatever it holds; a walk over ⊥, whose
/// answer is nothing, records its edge too.
fn tailCalls(mod: *Module, e: *Edges, decl: Bir.Decl) Error!void {
    if (e.recs.items.len == 0) return;
    const gpa = mod.gpa;
    const bir = mod.in.bir;
    var tail: Ids.FixedDict(1) = .{};
    defer tail.deinit(gpa);
    var todo: std.ArrayList(u32) = .empty;
    defer todo.deinit(gpa);
    if (decl.body.unwrap()) |b| try todo.append(gpa, b.int());
    while (todo.pop()) |i| {
        try mod.env().charge.reserve(gpa, .inspection, 1);
        const d = bir.instData(@fromBackingInt(i));
        switch (bir.instTag(@fromBackingInt(i))) {
            .let, .branch => try todo.append(gpa, d.rhs),
            .case => for (bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index)) |b| try todo.append(gpa, b.int()),
            .call, .method_call => _ = try tail.getOrPut(gpa, .{i}),
            else => {},
        }
    }
    for (e.recs.items) |*r| r.tail = tail.get(.{r.inst}) != null;
}

/// Moves `p.shape` when its `res` holds a cell at a path where its last
/// move's held none (*Ports*): the two shapes compared with every cell
/// set but the empty one read as one mark, `Shape.leq` per path.
fn shapeMove(mod: *Module, p: *Port) Error!void {
    const res = mod.sums.get(p.class).res;
    if (res == p.shape_res) return;
    const gpa = mod.gpa;
    const env = mod.env();
    const Marker = struct {
        set: Ids.SetId,
        fn one(m: *const @This(), s: Ids.SetId) Error!Ids.SetId {
            return if (s == .none) .none else m.set;
        }
    };
    const marker: Marker = .{ .set = try Summary.Table.marksSet(env, .{ .r = true }, &.{}) };
    const now = try mod.shapes.map(gpa, env.account(), res, &marker, Marker.one);
    const then = try mod.shapes.map(gpa, env.account(), p.shape_res, &marker, Marker.one);
    if (!try mod.shapes.leq(gpa, env.account(), env.places, env.cells, now, then)) p.shape += 1;
    p.shape_res = res;
}

/// One walk of member `k` against the ports as they stand, its read
/// vector in `g.reads`. Its first walk takes the source lanes' initial
/// copy, its second the validation copy, and every later one is growth,
/// reserved per instruction before it starts (*Charging*).
fn walkMember(mod: *Module, g: *Group, k: u32, prepass: *const Facts.Prepass, r: *DeclResult) Error!Walk.Result {
    const d = mod.in.bir.decls[g.members[k]];
    charging(mod, &r.account);
    mod.cur_locals = d.locals_start;
    r.account.source = d.inst_end.int() - d.inst_start.int();
    const copy: @TypeOf(r.account.walk) = switch (g.walks[k]) {
        0 => .inference,
        1 => .validation,
        else => .growth,
    };
    g.walks[k] += 1;
    if (copy == .growth) try r.account.reserveGrowth(.task, @intCast(r.account.source));
    r.account.walk = copy;
    defer r.account.walk = .inference;
    g.reads.clearRetainingCapacity();
    const run = g.param_runs.items[k];
    return Walk.walk(.{
        .env = mod.env(),
        .sums = &mod.sums,
        .ctx = mod.context(),
        .bir = mod.in.bir,
        .decl = d,
        .prepass = prepass,
        .phase = if (copy == .validation) .validation else .inference,
        .param_places = g.param_places.items[run.start..][0..run.len],
        .result_place = g.result_places.items[k],
        .labels = .{ .fresh = &g.fresh[k], .ctx = mod, .group_call = Module.isGroupCall },
        .comparison = mod.comparison[g.members[k]],
    });
}

/// C5, the induction checked again (§8 slice 4, *The proof is the stop
/// rule's*, #1485), under `--ownership-rewalk-check` and
/// `-Downership-full-cross-check` only: each member walked once more on
/// an account of its own, its walk counts and edges untouched, against the
/// settled ports x*: its read-off is below its port (the step, F(A) ⊑ A).
/// The base is the step's depth-1 case and is not walked apart: a walk
/// over ports at ⊥ makes views a later walk of the module meets, which
/// moves that walk's records (the chain's counted test).
fn checkInduction(mod: *Module, g: *Group, prepass: *const Facts.Prepass) Error!void {
    const gpa = mod.gpa;
    for (g.members, 0..) |di, k| {
        var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
        defer scratch.deinit(gpa);
        charging(mod, &scratch);
        const d = mod.in.bir.decls[di];
        mod.cur_locals = d.locals_start;
        scratch.source = d.inst_end.int() - d.inst_start.int();
        g.reads.clearRetainingCapacity();
        const run = g.param_runs.items[k];
        var res = try Walk.walk(.{
            .env = mod.env(),
            .sums = &mod.sums,
            .ctx = mod.context(),
            .bir = mod.in.bir,
            .decl = d,
            .prepass = prepass,
            .phase = .validation,
            .param_places = g.param_places.items[run.start..][0..run.len],
            .result_place = g.result_places.items[k],
            .labels = .{ .fresh = &g.fresh[k], .ctx = mod, .group_call = Module.isGroupCall },
            .comparison = mod.comparison[di],
        });
        defer res.deinit(gpa);
        if (res.unbuilt != none) std.debug.panic("ownership v2: a settled group's member is unbuilt when walked again (C5, #1485)", .{});
        if (!try mod.sums.leq(mod.env(), res.class, g.ports.items[k].class))
            std.debug.panic("ownership v2: the fold certificate's step fails: a member's read-off is not below its settled port (C5, #1485)", .{});
    }
}

/// `⊤call` over `d`'s places (O10).
fn pessimisticOf(mod: *Module, d: Bir.Decl, di: u32, places: *std.ArrayList(PlaceId)) Error!ClassId {
    const res = try declPlaces(mod, d, di, places);
    return mod.sums.unknown(mod.env(), places.items, &.{}, res);
}

/// The first call of `d` of a member of the group being solved: where a
/// member of a group that does not settle is unbuilt.
fn firstGroupCall(mod: *const Module, d: Bir.Decl) u32 {
    for (d.inst_start.int()..d.inst_end.int()) |i| if (mod.groupMember(@intCast(i)) != null) return @intCast(i);
    return d.body.unwrap().?.int();
}

/// The class a declaration of this module publishes (§3.6): its walk's,
/// or for a worded one or a `foreign` its words' over the places of its
/// own scheme (`Bir.ownSlotsV2`; the pessimistic default without words,
/// R-5.10.3). Null for a declaration that is no value.
pub fn declaredClass(mod: *Module, di: u32) Error!?ClassId {
    const d = mod.in.bir.decls[di];
    if (!d.kind.isValue()) return null;
    for (mod.results.items) |r| if (r.decl == di) return if (r.failure != null) null else r.class;
    // An alias of a function: its target's class (`Module.walkedClass`).
    if (mod.result_of[di] == none) if (mod.walkedClass(di)) |c| return c;
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

const v2_mutation = @import("ownership_options").v2_mutation;
const full_cross_check = @import("ownership_options").full_cross_check;

/// A test-only mutation (`-Downership-v2-mutation`, which `gates` refuses).
fn mutated(comptime which: []const u8) bool {
    return std.mem.eql(u8, v2_mutation, which);
}

// ===========================================================================
// Recursive contracts — an EXPERIMENT (`--ownership-contracts=1|2`, hidden).
//
// A recursive group's port is not v2's expanding result graph but a contract
// over a FIXED inventory read from the typed interface: per member, its use
// marks (joined), its `xreq`, and one origin set per canonical path of its
// result place (the slots). Each round builds the port afresh from the slots
// alone — a node per slot, its children the slots its steps reach, so the
// recursive structure is the place graph's and never a previous round's
// answer — walks every member once with v2's own walk against those ports,
// and abstracts the read-off back onto the slots (`alpha`). Rounds only add
// cells to a fixed set of slots and marks to a fixed set of paths, so they
// stop. Stage 1 publishes the slots with no stored κ: a built node reads
// `lost`, so the answer may alias its input and is never exclusive. Stage 2
// adds one predicate, inferred and checked from the BIR (`Tokens`): for each
// parameter, the most times one of its objects can occur in the answer, and
// whether fresh objects can repeat. Where every origin of a slot occurs at
// most once, the slot's node stores `yes`, which at a summary position reads
// `yes ∧ derived(cells)`: the answer keeps whatever separation the caller
// supplies, never more. Everything else — liveness, holders, demands,
// callers' checks — is v2's, unchanged.
// ===========================================================================

pub const ContractStats = struct {
    stage: u8 = 0,
    rounds: u32 = 0,
    slots: u32 = 0,
    slot_cells: u32 = 0,
    origins: u32 = 0,
    unknown_origins: u32 = 0,
    alpha_visits: u32 = 0,
    port_records: u32 = 0,
    tokens: u32 = 0,
    token_ops: u32 = 0,
    token_rounds: u32 = 0,
    validate_ops: u32 = 0,
    /// Per-parameter multiplicities the validated predicate publishes,
    /// packed two bits each (0, 1, 2 = repeated), parameter 1 lowest.
    mults: u32 = 0,
    fresh_dup: bool = false,
    preserved: bool = false,
    validated: bool = false,
    v2_leq: bool = false,
    v2_leq_uses: bool = false,
    certified: bool = false,
    reason: []const u8 = "",
    growth_at_walk2: u64 = 0,
    total_at_walk2: u64 = 0,
};

/// The slots of one member's result: its canonical paths, each with the
/// slots its steps reach and the origin cells α put there.
const Slots = struct {
    paths: std.ArrayList(Ids.PathId) = .empty,
    index: Ids.FixedDict(1) = .{},
    kid_runs: std.ArrayList(Ids.Range) = .empty,
    kids: std.ArrayList(struct { step: Step, slot: u32 }) = .empty,
    cells: std.ArrayList(Ids.SetId) = .empty,

    fn deinit(s: *Slots, gpa: Allocator) void {
        s.paths.deinit(gpa);
        s.index.deinit(gpa);
        s.kid_runs.deinit(gpa);
        s.kids.deinit(gpa);
        s.cells.deinit(gpa);
    }

    fn build(s: *Slots, mod: *Module, root_place: PlaceId) Error!void {
        const gpa = mod.gpa;
        const env = mod.env();
        const root = try mod.places.rootPath(gpa, root_place);
        _ = try s.add(gpa, root);
        var i: usize = 0;
        var pending: std.ArrayList(struct { step: Step, slot: u32 }) = .empty;
        defer pending.deinit(gpa);
        while (i < s.paths.items.len) : (i += 1) {
            const p = s.paths.items[i];
            const st = mod.places.steps(mod.places.pathPlace(p));
            pending.clearRetainingCapacity();
            for (st.steps) |step| {
                try env.charge.reserve(gpa, .path, 1);
                const q = (try mod.places.extend(gpa, env.charge, p, step)) orelse continue;
                const j = try s.add(gpa, q);
                try pending.append(gpa, .{ .step = step, .slot = j });
            }
            const start: u32 = @intCast(s.kids.items.len);
            for (pending.items) |k| try s.kids.append(gpa, .{ .step = k.step, .slot = k.slot });
            try s.kid_runs.append(gpa, .{ .start = start, .len = @intCast(pending.items.len) });
        }
    }

    fn add(s: *Slots, gpa: Allocator, p: Ids.PathId) Allocator.Error!u32 {
        const got = try s.index.getOrPut(gpa, .{p.int()});
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(s.paths.items.len);
            try s.paths.append(gpa, p);
            try s.cells.append(gpa, .none);
        }
        return got.value_ptr.*;
    }
};

/// A member's contract while the group is solved.
const Contract = struct {
    slots: Slots = .{},
    /// The joined use marks, `xreq` and bits: a class whose `res` is nothing.
    uses: ClassId = .none,
    /// The stage-2 predicate: per parameter its multiplicity, fresh repeats.
    mults: []u2 = &.{},
    fresh_dup: bool = false,
    preserved: bool = false,
    stats: ContractStats = .{},
};

/// Whether the experiment takes this group: first order only (no function
/// in a parameter or the result, no lambda in a body). A higher-order group
/// is v2's (the second checkpoint of the review, not this one).
fn contractScope(mod: *Module, members: []const u32) Error!bool {
    var places: std.ArrayList(PlaceId) = .empty;
    defer places.deinit(mod.gpa);
    var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
    defer scratch.deinit(mod.gpa);
    const saved = mod.account;
    charging(mod, &scratch);
    defer charging(mod, saved);
    for (members) |di| {
        mod.cur_locals = mod.in.bir.decls[di].locals_start;
        try places.append(mod.gpa, try declPlaces(mod, mod.in.bir.decls[di], di, &places));
    }
    for (places.items) |p| if (mod.places.holds(p).closure or mod.places.kind(p) == .closure) return false;
    const bir = mod.in.bir;
    for (members) |di| {
        const d = bir.decls[di];
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) switch (bir.instTag(@fromBackingInt(i))) {
            .lambda => return false,
            .let_def => {
                const def = bir.extraData(@fromBackingInt(bir.instData(@fromBackingInt(i)).lhs), Bir.LetDef);
                if (def.params_end != def.params_start) return false;
            },
            else => {},
        };
    }
    return true;
}

/// α: the read-off's `res` onto the slots. A pair `(slot, node)` is visited
/// once; a node's cells at `ε` go into its slot, each mapped onto the
/// inventory (`mapCell`), and its projection by each of the slot's steps is
/// visited at the slot that step reaches. Nothing of the read-off's
/// structure survives but the cells per slot.
fn alpha(mod: *Module, c: *Contract, res: Ids.NodeId) Error!bool {
    const gpa = mod.gpa;
    const env = mod.env();
    var seen: Ids.FixedDict(2) = .{};
    defer seen.deinit(gpa);
    var todo: std.ArrayList([2]u32) = .empty;
    defer todo.deinit(gpa);
    var grew = false;
    try todo.append(gpa, .{ 0, res.int() });
    _ = try seen.getOrPut(gpa, .{ 0, res.int() });
    while (todo.pop()) |x| {
        try env.charge.reserve(gpa, .inspection, 1);
        c.stats.alpha_visits += 1;
        const slot = x[0];
        const n: Ids.NodeId = .from(x[1]);
        // A join's sides are read one by one at its slot: the join's own
        // cell set lets an exact occurrence mask an approximate one.
        switch (mod.shapes.kind(n)) {
            .@"union", .choice, .positions => {
                const nd = mod.shapes.get(n);
                for ([_]u32{ nd.a, nd.b }) |side| {
                    const got = try seen.getOrPut(gpa, .{ slot, side });
                    if (!got.found_existing) try todo.append(gpa, .{ slot, side });
                }
                continue;
            },
            else => {},
        }
        const cs = try mod.shapes.cellsOf(gpa, mod.account, &mod.cells.sets, n);
        // A recast's cells are its inner's, approximate at every path: the
        // node kind carries that, so the slot keeps it as the approx bit.
        const recast = mod.shapes.kind(n) == .recast;
        if (alpha_trace) {
            std.debug.print("alpha slot {d} node {d} kind {t} cells:", .{ slot, n.int(), mod.shapes.kind(n) });
            var it2 = mod.cells.sets.iterate(cs);
            while (it2.next()) |e| std.debug.print(" {t}{d}.{d}~{d}", .{ mod.cells.origin(.from(e.key)), mod.cells.get(.from(e.key)).a, mod.cells.get(.from(e.key)).b, e.value });
            std.debug.print(" kids:", .{});
            if (mod.shapes.kind(n) == .node) {
                var oi = mod.shapes.overEntries(mod.shapes.get(n).a);
                while (oi.next()) |e| std.debug.print(" {d}", .{e.node.int()});
            } else if (mod.shapes.kind(n) != .leaf) std.debug.print(" a={d} b={d}", .{ mod.shapes.get(n).a, mod.shapes.get(n).b });
            std.debug.print("\n", .{});
        }
        var it = mod.cells.sets.iterate(cs);
        while (it.next()) |e| {
            const mapped = try mapCell(mod, c, slot, .from(e.key));
            const before = c.slots.cells.items[slot];
            const had = mod.cells.sets.get(before, mapped.int());
            const bit: u1 = if (recast or e.value == 1 or (had != null and had.? == 1)) 1 else 0;
            const after = try mod.cells.sets.insert(gpa, env.charge, before, mapped.int(), bit);
            if (after != before) {
                c.slots.cells.items[slot] = after;
                grew = true;
            }
        }
        const run = c.slots.kid_runs.items[slot];
        for (c.slots.kids.items[run.start..][0..run.len]) |k| {
            const m = (try mod.shapes.proj(gpa, mod.account, &mod.places, &mod.cells, n, k.step)) orelse continue;
            const got = try seen.getOrPut(gpa, .{ k.slot, m.int() });
            if (!got.found_existing) try todo.append(gpa, .{ k.slot, m.int() });
        }
    }
    return grew;
}

/// A read-off cell as an origin of the inventory: a parameter's cell, `⊤`
/// and `shared` as they are; an object made in an activation (`fresh k`,
/// `esc k`) as it is too — read-off numbers them by the group's stable
/// allocation keys, so one allocation is ONE cell at every slot it reaches
/// and two slots holding it alias (renaming it per slot lost that: #pushDup);
/// anything else (a callback's, a refinement) as `⊤`, so unknown is never
/// empty.
fn mapCell(mod: *Module, c: *Contract, slot: u32, x: Ids.CellId) Error!Ids.CellId {
    const env = mod.env();
    _ = slot;
    return switch (mod.cells.origin(x)) {
        .param, .top, .shared, .result, .esc => x,
        .site => x,
        else => blk: {
            c.stats.unknown_origins += 1;
            break :blk try mod.cells.top(env.gpa, mod.account);
        },
    };
}

/// The port a contract stands for: a node per slot, tied into the place
/// graph's own cycles, κ `yes` stored at a slot's node only where the
/// stage-2 predicate holds for every origin in it.
fn synthPort(mod: *Module, g: *Group, k: usize, c: *Contract) Error!ClassId {
    const gpa = mod.gpa;
    const env = mod.env();
    const before = mod.shapes.count();
    const n = c.slots.paths.items.len;
    const knots = try gpa.alloc(Ids.NodeId, n);
    defer gpa.free(knots);
    for (knots) |*x| x.* = try mod.shapes.knot(gpa, mod.account);
    // A preserved slot stores the condition its own arrivals read at a
    // summary position, as atoms (`summaryExcl ∧ apart`), never bare `yes`:
    // instantiation must see the pair (two arrivals one caller cell is
    // `apart(b, b)`, refused), which a derived read of the instantiated
    // cell SET would have collapsed.
    const good = try gpa.alloc(?Ids.CondId, n);
    defer gpa.free(good);
    @memset(good, null);
    // The node each slot's κ is stored under: its plain part.
    const keyed = try gpa.alloc(Ids.NodeId, n);
    defer gpa.free(keyed);
    for (0..n) |i| {
        var over: u32 = none;
        const run = c.slots.kid_runs.items[i];
        for (c.slots.kids.items[run.start..][0..run.len]) |kid| over = try mod.shapes.overPut(gpa, mod.account, over, kid.step, knots[kid.slot]);
        const at = mod.places.pathPlace(c.slots.paths.items[i]);
        // A place with no steps (a type variable, an opaque or crossing
        // leaf) is a LEAF: below it, whatever its symbolic cells project to
        // (only parameter cells reach such a place). A built node there
        // would say "nothing below" and drop every read and alias a caller
        // makes through the answer at its own type (#1350's re-rooting).
        const leafy = mod.places.steps(at).steps.len == 0;
        // Approximate cells (a recast's, `~πᵢ·q`) keep their meaning — the
        // inner's cells at every path below — as a recast over a leaf of
        // them, joined with the slot's exact cells and children; copied into
        // a plain node they would name only the object at the slot itself.
        var exact: Ids.SetId = .none;
        var approx: std.ArrayList(Ids.CellId) = .empty;
        defer approx.deinit(gpa);
        var it = mod.cells.sets.iterate(c.slots.cells.items[i]);
        while (it.next()) |e| {
            if (e.value == 1) try approx.append(gpa, .from(e.key)) else exact = try mod.cells.sets.insert(gpa, env.charge, exact, e.key, 0);
        }
        const plain_rec: Shape.Node = .{ .kind = if (leafy) .leaf else .node, .place = at, .cells = exact, .a = if (leafy) 0 else over, .b = 0, .reach = .none };
        if (approx.items.len == 0) {
            mod.shapes.tie(knots[i], plain_rec);
            keyed[i] = knots[i];
        } else {
            const plain = try mod.shapes.knot(gpa, mod.account);
            mod.shapes.tie(plain, plain_rec);
            keyed[i] = plain;
            var acc: Ids.NodeId = .none;
            for (approx.items) |x| {
                const pl0 = mod.cells.place(x);
                const pl = if (pl0 == .none) at else pl0;
                const lf = try mod.shapes.leaf(gpa, mod.account, pl, try mod.cells.sets.insert(gpa, env.charge, .none, x.int(), 1));
                const r = if (pl == at) lf else try mod.shapes.recast(gpa, mod.account, at, lf);
                acc = if (acc == .none) r else try mod.shapes.@"union"(gpa, mod.account, &mod.cells.sets, acc, r);
            }
            mod.shapes.tie(knots[i], .{ .kind = .@"union", .place = at, .cells = try mod.cells.sets.unionWith(gpa, env.charge, exact, try mod.shapes.cellsOf(gpa, mod.account, &mod.cells.sets, acc)), .a = plain.int(), .b = acc.int(), .reach = .none });
        }
        if (c.preserved and try slotPreserved(mod, c, c.slots.cells.items[i])) {
            const kd = try mod.conds.derivedCells(gpa, env.charge, env.view(), c.slots.cells.items[i], true, .none, .none);
            if (kd != Cond.lost and kd != Cond.shared) good[i] = kd else if (leafy) good[i] = Cond.lost;
        } else if (leafy) good[i] = Cond.lost;
    }
    var kappas: Cond.Kappas = .none;
    if (std.mem.indexOfNone(?Ids.CondId, good, &.{null}) != null) {
        // κ as v2 stores it: a trie of positions along the slot graph's
        // steps, and an exact fold where a slot lies on a cycle (every slot
        // the cycle reaches keyed at it).
        const memo = try gpa.alloc(?Cond.Kappas, n);
        defer gpa.free(memo);
        @memset(memo, null);
        kappas = try kappaPos(mod, c, keyed, good, memo, 0);
    }
    const u = mod.sums.get(c.uses);
    _ = g;
    _ = k;
    const params = try gpa.dupe(Ids.NodeId, mod.sums.paramUses(c.uses));
    defer gpa.free(params);
    const cls = try mod.sums.add(env, .{
        .params = params,
        .res = knots[0],
        .kappas = kappas,
        .xreq = u.xreq,
        .refs = u.refs,
        .refs_top = u.refs_top,
        .writes = u.writes,
        .origin = .inferred,
    });
    c.stats.port_records = mod.shapes.count() - before;
    return cls;
}

fn reaches(c: *Contract, from: u32, to: u32, gpa: Allocator) Allocator.Error!bool {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    var todo: std.ArrayList(u32) = .empty;
    defer todo.deinit(gpa);
    try todo.append(gpa, from);
    while (todo.pop()) |x| {
        const run = c.slots.kid_runs.items[x];
        for (c.slots.kids.items[run.start..][0..run.len]) |k| {
            if (k.slot == to) return true;
            if ((try seen.getOrPut(gpa, k.slot)).found_existing) continue;
            try todo.append(gpa, k.slot);
        }
    }
    return false;
}

fn kappaPos(mod: *Module, c: *Contract, knots: []const Ids.NodeId, good: []const ?Ids.CondId, memo: []?Cond.Kappas, i: u32) Error!Cond.Kappas {
    if (memo[i]) |m| return m;
    const gpa = mod.gpa;
    const env = mod.env();
    if (try reaches(c, i, i, gpa)) {
        // A cycle: one exact fold holding every slot reachable from here.
        var here: u32 = none;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(gpa);
        var todo: std.ArrayList(u32) = .empty;
        defer todo.deinit(gpa);
        try todo.append(gpa, i);
        _ = try seen.getOrPut(gpa, i);
        while (todo.pop()) |x| {
            if (good[x]) |k| here = try mod.conds.mapPut(gpa, env.charge, here, knots[x].int(), k.int());
            const run = c.slots.kid_runs.items[x];
            for (c.slots.kids.items[run.start..][0..run.len]) |k| if (!(try seen.getOrPut(gpa, k.slot)).found_existing) try todo.append(gpa, k.slot);
        }
        const p = if (here == none) Cond.Kappas.none else try mod.conds.makePos(gpa, env.charge, .{ .here = here, .links = none, .fold = Cond.Table.fold_exact });
        memo[i] = p;
        return p;
    }
    var here: u32 = none;
    if (good[i]) |k| here = try mod.conds.mapPut(gpa, env.charge, here, knots[i].int(), k.int());
    var links: u32 = none;
    const run = c.slots.kid_runs.items[i];
    for (c.slots.kids.items[run.start..][0..run.len]) |k| {
        const sub = try kappaPos(mod, c, knots, good, memo, k.slot);
        if (sub != .none) links = try mod.conds.mapPut(gpa, env.charge, links, k.step.word(), sub.int());
    }
    const p = try mod.conds.makePos(gpa, env.charge, .{ .here = here, .links = links, .fold = 0 });
    memo[i] = p;
    return p;
}

fn slotPreserved(mod: *Module, c: *Contract, cs: Ids.SetId) Error!bool {
    var it = mod.cells.sets.iterate(cs);
    while (it.next()) |e| {
        const x: Ids.CellId = .from(e.key);
        switch (mod.cells.origin(x)) {
            .param => {
                const i = mod.cells.get(x).a;
                if (i >= c.mults.len or c.mults[i] > 1) return false;
            },
            .result => if (c.fresh_dup) return false,
            else => return false,
        }
    }
    return true;
}

/// The top of the vocabulary at every slot: each parameter's cell at each
/// of its canonical paths whose place is the slot's, and the slot's fresh cell.
fn seedSlots(mod: *Module, g: *Group, k: usize, c: *Contract) Error!void {
    const gpa = mod.gpa;
    const env = mod.env();
    const run = g.param_runs.items[k];
    for (g.param_places.items[run.start..][0..run.len], 0..) |pp, i| {
        var ps: Slots = .{};
        defer ps.deinit(gpa);
        try ps.build(mod, pp);
        for (ps.paths.items) |q| {
            const cell = try mod.cells.symbolic(gpa, mod.account, &mod.places, .param, @intCast(i), q, 0);
            for (c.slots.paths.items, 0..) |p, si| if (mod.places.pathPlace(p) == mod.places.pathPlace(q)) {
                c.slots.cells.items[si] = try mod.cells.sets.insert(gpa, env.charge, c.slots.cells.items[si], cell.int(), 0);
            };
        }
    }
    for (c.slots.paths.items, 0..) |p, si| {
        const at = mod.places.pathPlace(p);
        const fresh = try mod.cells.result(gpa, mod.account, .result, .none, @intCast(si), at, Cell.Kind.ofPlace(mod.places.kind(at)));
        c.slots.cells.items[si] = try mod.cells.sets.insert(gpa, env.charge, c.slots.cells.items[si], fresh.int(), 0);
    }
}

/// A class with the read-off's marks, `xreq` and bits and no answer: what
/// the contract keeps of a walk besides its slots.
fn usesOf(mod: *Module, f: ClassId, result_place: PlaceId) Error!ClassId {
    const env = mod.env();
    const c = mod.sums.get(f);
    const params = try env.gpa.dupe(Ids.NodeId, mod.sums.paramUses(f));
    defer env.gpa.free(params);
    return mod.sums.add(env, .{
        .params = params,
        .res = try mod.shapes.nothing(env.gpa, mod.account, result_place),
        .xreq = c.xreq,
        .refs = c.refs,
        .refs_top = c.refs_top,
        .writes = c.writes,
        .origin = .inferred,
    });
}

const contract_trace = false;
const tok_trace = false;
const alpha_trace = false;

fn runContractGroup(mod: *Module, g: *Group, prepass: *const Facts.Prepass, rs: []DeclResult) Error!bool {
    const gpa = mod.gpa;
    const n = g.members.len;
    g.fresh = try gpa.alloc(Ids.FixedDict(3), n);
    @memset(g.fresh, .{});
    g.walks = try gpa.alloc(u32, n);
    @memset(g.walks, 0);
    g.inference = try gpa.alloc(u32, n);
    @memset(g.inference, 0);
    g.deliveries = try gpa.alloc(u32, n);
    @memset(g.deliveries, 0);
    g.lines = try gpa.alloc([]Walk.Line, n);
    @memset(g.lines, &.{});
    g.out = try gpa.alloc(ClassId, n);
    g.vectors = try gpa.alloc(Ids.Range, n);
    @memset(g.vectors, .{ .start = 0, .len = 0 });
    g.edges = try gpa.alloc(Edges, n);
    @memset(g.edges, .{});
    g.queued = try gpa.alloc(bool, n);
    @memset(g.queued, false);
    g.callers = try gpa.alloc(std.ArrayList([2]u32), n);
    @memset(g.callers, .empty);
    const cs = try gpa.alloc(Contract, n);
    defer {
        for (cs) |*c| {
            c.slots.deinit(gpa);
            gpa.free(c.mults);
        }
        gpa.free(cs);
    }
    @memset(cs, .{});
    for (g.members, 0..) |di, k| {
        (try g.index.getOrPut(gpa, .{di})).value_ptr.* = @intCast(k);
        const d = mod.in.bir.decls[di];
        charging(mod, &rs[k].account);
        rs[k].account.source = d.inst_end.int() - d.inst_start.int();
        mod.cur_locals = d.locals_start;
        const start: u32 = @intCast(g.param_places.items.len);
        const res = try declPlaces(mod, d, di, &g.param_places);
        try g.param_runs.append(gpa, .{ .start = start, .len = @intCast(g.param_places.items.len - start) });
        try g.result_places.append(gpa, res);
        const uses = try gpa.alloc(Ids.NodeId, g.param_places.items.len - start);
        defer gpa.free(uses);
        @memset(uses, .none);
        cs[k].stats.stage = mod.in.contracts;
        cs[k].uses = try mod.sums.add(mod.env(), .{ .params = uses, .res = try mod.shapes.nothing(gpa, mod.account, res) });
        try cs[k].slots.build(mod, res);
        cs[k].mults = try gpa.alloc(u2, g.param_runs.items[k].len);
        @memset(cs[k].mults, 2);
        try g.ports.append(gpa, .{ .class = .none, .version = 0, .shape_res = .none });
    }
    // Stage 2: the predicate, inferred and validated from the BIR alone,
    // before any walk (it reads no port).
    if (mod.in.contracts >= 2 and mod.in.contracts != 8) try inferTokens(mod, g, cs, rs);
    // Seeded (6, 7): every slot starts with every parameter cell of its
    // place and its fresh cell, the top of the vocabulary; the first
    // round REPLACES the slots by its read-off (a descending step, sound
    // because any post-fixed point is), the later ones add as before.
    const seeded = mod.in.contracts == 6 or mod.in.contracts == 7;
    if (seeded) for (cs, 0..) |*c, k| {
        charging(mod, &rs[k].account);
        try seedSlots(mod, g, k, c);
    };
    var first = true;
    while (true) {
        for (cs, 0..) |*c, k| {
            charging(mod, &rs[k].account);
            g.ports.items[k].class = try synthPort(mod, g, k, c);
            g.ports.items[k].version += 1;
        }
        for (g.members, 0..) |_, k| {
            g.staging.clear();
            g.walking = @intCast(k);
            var res = walkMember(mod, g, @intCast(k), prepass, &rs[k]) catch |err| {
                g.walking = none;
                return err;
            };
            g.walking = none;
            if (res.unbuilt != none) {
                res.deinit(gpa);
                rs[k].unbuilt = res.unbuilt;
                rs[k].polymorphic = res.unbuilt == g.poly;
                return false;
            }
            g.inference[k] += 1;
            gpa.free(g.lines[k]);
            g.lines[k] = res.lines;
            g.out[k] = res.class;
            if (contract_trace) std.debug.print("contract walk {d} member {d}: growth {d} total {d} port nodes {d}\n", .{ g.walks[k], k, rs[k].account.growth, rs[k].account.total(), cs[k].stats.port_records });
            if (g.walks[k] == 2) {
                cs[k].stats.growth_at_walk2 = rs[k].account.growth;
                cs[k].stats.total_at_walk2 = rs[k].account.total();
            }
        }
        var changed = false;
        for (cs, 0..) |*c, k| {
            charging(mod, &rs[k].account);
            const u = try usesOf(mod, g.out[k], g.result_places.items[k]);
            if (!try mod.sums.leq(mod.env(), u, c.uses)) {
                c.uses = try mod.sums.join(mod.env(), c.uses, u, .choice);
                changed = true;
            }
            if (seeded and first) {
                @memset(c.slots.cells.items, .none);
                _ = try alpha(mod, c, mod.sums.get(g.out[k]).res);
                changed = true;
            } else if (try alpha(mod, c, mod.sums.get(g.out[k]).res)) changed = true;
        }
        first = false;
        for (cs) |*c| c.stats.rounds += 1;
        if (contract_trace) for (cs, 0..) |*c, k| {
            var sc: u32 = 0;
            for (c.slots.cells.items) |x| sc += mod.cells.sets.count(x);
            std.debug.print("contract round {d} member {d}: changed {}, slots {d}, slot cells {d}, growth {d}\n", .{ c.stats.rounds, k, changed, c.slots.paths.items.len, sc, rs[k].account.growth });
        };
        if (!changed) break;
    }
    // The last round's walks read the ports as they stand and changed no
    // slot and no mark: the contract is a post-fixed point of the walk on
    // its own inventory, and those walks are the validation (their lines
    // are reported). v2's own `leq` of each read-off under its port is
    // recorded beside it, as a cross-check only.
    for (rs, cs, 0..) |*r, *c, k| {
        charging(mod, &r.account);
        c.stats.v2_leq = try mod.sums.leq(mod.env(), g.out[k], g.ports.items[k].class);
        c.stats.v2_leq_uses = try mod.sums.leq(mod.env(), try usesOf(mod, g.out[k], g.result_places.items[k]), c.uses);
        c.stats.slots = @intCast(c.slots.paths.items.len);
        var origins: Ids.SetId = .none;
        for (c.slots.cells.items) |s| {
            c.stats.slot_cells += mod.cells.sets.count(s);
            origins = try mod.cells.sets.unionWith(gpa, mod.env().charge, origins, s);
        }
        c.stats.origins = mod.cells.sets.count(origins);
        c.stats.preserved = c.preserved;
        c.stats.fresh_dup = c.fresh_dup;
        for (c.mults, 0..) |m, i| if (i < 16) {
            c.stats.mults |= @as(u32, m) << @intCast(2 * i);
        };
        r.class = g.ports.items[k].class;
        // The fold certificate (§8 slice 4): published only where the
        // validated predicate implies its claim — every parameter object and
        // every fresh object at most once in the whole answer, so at most
        // once in each folded class. Its readers then read the class exactly.
        if (c.preserved and !c.fresh_dup and std.mem.indexOfScalar(u2, c.mults, 2) == null) {
            try mod.sums.certify(gpa, r.class);
            c.stats.certified = true;
            r.contract = c.stats;
        }
        r.walks = g.walks[k];
        r.inference = g.inference[k];
        r.deliveries = g.deliveries[k];
        r.lines = g.lines[k];
        g.lines[k] = &.{};
        r.contract = c.stats;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Stage 2: occurrence tokens over the BIR.
//
// A token is an object the body can name: a parameter's (`πᵢ` and a path of
// pattern steps below it), one a site makes in this activation, or a part of
// an opaque value (a call's answer, a choice's join) by its path below it.
// Two tokens of one root overlap when one path is a prefix of the other; of
// two roots, never — the caller's separation is the assumption (published
// as the conditional κ, never as a fact). An opaque value is a multiset of
// older tokens (its expansion) and a bit, `clean`: no object occurs twice
// in it, so two disjoint parts of it hold disjoint objects. A call's
// expansion is each argument's tokens times the callee's multiplicity for
// that parameter, plus the call's own fresh token (repeated when the
// callee's fresh objects may repeat). Alternatives take the maximum: each
// tail arm is counted alone, and a non-tail choice is an opaque value whose
// expansion keeps the larger multiplicity per token. Components built
// together add, saturating at 2 ("repeated"). Values whose place holds no
// storage carry no token.
//
// A group's predicate is the least fixed point from "nothing returned"
// (every multiplicity 0): it only rises, two bits per parameter. It is then
// VALIDATED by a separate pass: each body evaluated once more with the
// group's calls answered by the candidate, its answer's multiplicities
// compared with the candidate's (the base — an arm with no group call — and
// the step are both in that one evaluation; nothing it reads came from the
// inference). A candidate the validator refuses is not published: its
// member keeps stage 1's κ.
// ---------------------------------------------------------------------------

const TokRoot = enum(u8) { param, fresh, opq };

const Tokens = struct {
    gpa: Allocator,
    mod: *Module,
    // token table
    parent: std.ArrayList(u32) = .empty,
    step: std.ArrayList(u32) = .empty,
    depth: std.ArrayList(u32) = .empty,
    root: std.ArrayList(u32) = .empty,
    root_kind: std.ArrayList(TokRoot) = .empty,
    root_arg: std.ArrayList(u32) = .empty,
    intern: Ids.FixedDict(3) = .{},
    // opaque values
    opq_exp: std.ArrayList(Ids.Range) = .empty,
    opq_clean: std.ArrayList(bool) = .empty,
    occs: std.ArrayList(Occ) = .empty,
    // values
    vals: std.ArrayList(V) = .empty,
    vkids: std.ArrayList(u32) = .empty,
    locals: Ids.FixedDict(1) = .{},
    ops: u32 = 0,
    failed: ?[]const u8 = null,
    /// The group's candidate, read at its calls.
    cand: []const Cand = &.{},
    /// Same-module declarations analysed on demand (not in the group).
    cache: std.AutoHashMapUnmanaged(u32, Cand) = .empty,
    busy: std.AutoHashMapUnmanaged(u32, void) = .empty,
    cache_mults: std.ArrayList([]u2) = .empty,

    const Occ = struct { tok: u32, mult: u2 };
    const V = struct { kind: enum(u8) { none, tok, con }, tok: u32 = none, ctor: u32 = none, kids: Ids.Range = .{ .start = 0, .len = 0 } };
    const Cand = struct { mults: []u2, fresh_dup: bool };

    fn deinit(t: *Tokens) void {
        const gpa = t.gpa;
        t.parent.deinit(gpa);
        t.step.deinit(gpa);
        t.depth.deinit(gpa);
        t.root.deinit(gpa);
        t.root_kind.deinit(gpa);
        t.root_arg.deinit(gpa);
        t.intern.deinit(gpa);
        t.opq_exp.deinit(gpa);
        t.opq_clean.deinit(gpa);
        t.occs.deinit(gpa);
        t.vals.deinit(gpa);
        t.vkids.deinit(gpa);
        t.locals.deinit(gpa);
        t.cache.deinit(gpa);
        t.busy.deinit(gpa);
        for (t.cache_mults.items) |m| gpa.free(m);
        t.cache_mults.deinit(gpa);
    }

    fn op(t: *Tokens) Error!void {
        t.ops += 1;
        try t.mod.env().charge.reserve(t.gpa, .inspection, 1);
    }

    fn rootTok(t: *Tokens, kind: TokRoot, arg: u32) Error!u32 {
        return t.mk(none, (@as(u32, @backingInt(kind)) << 30) | arg, kind, arg);
    }

    fn child(t: *Tokens, p: u32, s: u32) Error!u32 {
        return t.mk(p, s, t.root_kind.items[t.root.items[p]], 0);
    }

    fn mk(t: *Tokens, p: u32, s: u32, kind: TokRoot, arg: u32) Error!u32 {
        try t.op();
        const got = try t.intern.getOrPut(t.gpa, .{ p, s, if (p == none) arg else 0 });
        if (got.found_existing) return got.value_ptr.*;
        const id: u32 = @intCast(t.parent.items.len);
        got.value_ptr.* = id;
        try t.parent.append(t.gpa, p);
        try t.step.append(t.gpa, s);
        try t.depth.append(t.gpa, if (p == none) 0 else t.depth.items[p] + 1);
        try t.root.append(t.gpa, if (p == none) id else t.root.items[p]);
        try t.root_kind.append(t.gpa, kind);
        try t.root_arg.append(t.gpa, if (p == none) arg else t.root_arg.items[t.root.items[p]]);
        return id;
    }

    /// Whether one token's path is a prefix of the other's, in one root.
    fn overlap(t: *Tokens, a: u32, b: u32) Error!bool {
        try t.op();
        if (t.root.items[a] != t.root.items[b]) return false;
        var x = a;
        var y = b;
        while (t.depth.items[x] > t.depth.items[y]) x = t.parent.items[x];
        while (t.depth.items[y] > t.depth.items[x]) y = t.parent.items[y];
        return x == y;
    }

    fn val(t: *Tokens, v: V) Allocator.Error!u32 {
        try t.vals.append(t.gpa, v);
        return @intCast(t.vals.items.len - 1);
    }

    fn noneVal(t: *Tokens) Allocator.Error!u32 {
        return t.val(.{ .kind = .none });
    }

    fn holdsStorage(t: *Tokens, at: PlaceId) bool {
        if (at == .none) return true;
        const places = &t.mod.places;
        return !places.holds(at).isEmpty() or !Place.Kind.own(places.kind(at)).isEmpty();
    }

    fn instHolds(t: *Tokens, inst: u32) Error!bool {
        return t.holdsStorage(try Module.placeOfInst(t.mod, inst));
    }

    fn localHolds(t: *Tokens, local: u32) Error!bool {
        return t.holdsStorage(try Module.placeOfLocal(t.mod, local));
    }

    fn ownsCell(t: *Tokens, inst: u32) Error!bool {
        const at = try Module.placeOfInst(t.mod, inst);
        if (at == .none) return false;
        return !Place.Kind.own(t.mod.places.kind(at)).isEmpty();
    }

    // ---- flattening and counting --------------------------------------

    fn flatten(t: *Tokens, v: u32, k: u2, out: *std.ArrayList(Occ)) Error!void {
        try t.op();
        if (k == 0) return;
        const x = t.vals.items[v];
        switch (x.kind) {
            .none => {},
            .tok => try out.append(t.gpa, .{ .tok = x.tok, .mult = k }),
            .con => {
                if (x.tok != none) try out.append(t.gpa, .{ .tok = x.tok, .mult = k });
                var i: u32 = 0;
                while (i < x.kids.len) : (i += 1) try t.flatten(t.vkids.items[x.kids.start + i], k, out);
            },
        }
    }

    fn sat(a: u32) u2 {
        return @intCast(@min(a, 2));
    }

    /// Opaque roots replaced by their expansions, newest first, each group
    /// of parts of one opaque value counted once when the value is clean
    /// and the parts are disjoint and none is the whole.
    fn resolve(t: *Tokens, occs: *std.ArrayList(Occ)) Error!void {
        while (true) {
            var newest: u32 = none;
            for (occs.items) |o| {
                const r = t.root.items[o.tok];
                if (t.root_kind.items[r] != .opq) continue;
                const a = t.root_arg.items[r];
                if (newest == none or a > newest) newest = a;
            }
            if (newest == none) return;
            var group: std.ArrayList(Occ) = .empty;
            defer group.deinit(t.gpa);
            var i: usize = 0;
            while (i < occs.items.len) {
                const o = occs.items[i];
                const r = t.root.items[o.tok];
                if (t.root_kind.items[r] == .opq and t.root_arg.items[r] == newest) {
                    try group.append(t.gpa, o);
                    _ = occs.swapRemove(i);
                } else i += 1;
            }
            var whole = false;
            var disjoint = true;
            var mx: u2 = 0;
            var sum: u32 = 0;
            for (group.items, 0..) |o, a| {
                try t.op();
                if (t.depth.items[o.tok] == 0) whole = true;
                mx = @max(mx, o.mult);
                sum += o.mult;
                for (group.items[a + 1 ..]) |o2| if (try t.overlap(o.tok, o2.tok)) {
                    disjoint = false;
                };
            }
            const kv: u2 = if (!whole and disjoint and t.opq_clean.items[newest]) mx else sat(sum);
            const r = t.opq_exp.items[newest];
            var j: u32 = 0;
            while (j < r.len) : (j += 1) {
                const e = t.occs.items[r.start + j];
                try occs.append(t.gpa, .{ .tok = e.tok, .mult = sat(@as(u32, e.mult) * kv) });
            }
        }
    }

    /// Per base token its total multiplicity: the sum over the occurrences
    /// that overlap it, saturated. Into `mults` (per parameter, the max)
    /// and the fresh repeat bit; true when no token repeats.
    fn count(t: *Tokens, occs: []const Occ, mults: []u2, fresh_dup: *bool) Error!bool {
        var clean = true;
        for (occs) |o| {
            var total: u32 = 0;
            for (occs) |o2| if (try t.overlap(o.tok, o2.tok)) {
                total += o2.mult;
            };
            const m = sat(total);
            if (m >= 2) clean = false;
            const r = t.root.items[o.tok];
            switch (t.root_kind.items[r]) {
                .param => {
                    const i = t.root_arg.items[r];
                    if (i < mults.len) mults[i] = @max(mults[i], m);
                },
                .fresh => if (m >= 2) {
                    fresh_dup.* = true;
                },
                .opq => unreachable,
            }
        }
        return clean;
    }

    // ---- an opaque value ------------------------------------------------

    fn opq(t: *Tokens, exp: []const Occ, clean: bool) Error!u32 {
        const start: u32 = @intCast(t.occs.items.len);
        try t.occs.appendSlice(t.gpa, exp);
        const id: u32 = @intCast(t.opq_exp.items.len);
        try t.opq_exp.append(t.gpa, .{ .start = start, .len = @intCast(exp.len) });
        try t.opq_clean.append(t.gpa, clean);
        return t.val(.{ .kind = .tok, .tok = try t.rootTok(.opq, id) });
    }

    /// Whether a value, resolved, repeats no object.
    fn isClean(t: *Tokens, v: u32) Error!bool {
        var occs: std.ArrayList(Occ) = .empty;
        defer occs.deinit(t.gpa);
        try t.flatten(v, 1, &occs);
        try t.resolve(&occs);
        var dummy: [0]u2 = .{};
        var fd = false;
        return try t.count(occs.items, &dummy, &fd) and !fd;
    }

    // ---- the walk -------------------------------------------------------

    fn bir(t: *Tokens) *const Bir {
        return t.mod.in.bir;
    }

    fn tag(t: *Tokens, i: u32) Bir.Inst.Tag {
        return t.bir().instTag(@fromBackingInt(i));
    }

    fn data(t: *Tokens, i: u32) Bir.Inst.Data {
        return t.bir().instData(@fromBackingInt(i));
    }

    fn fail(t: *Tokens, why: []const u8) void {
        if (t.failed == null) t.failed = why;
    }

    fn ctorKey(t: *Tokens, ref: u32) ?u32 {
        const c = Module.ctorOf(t.mod, ref) orelse return null;
        return c[0];
    }

    const tuple_key: u32 = 0xFFFF;
    fn stepWord(kind: u32, a: u32, b: u32) u32 {
        return (kind << 28) | ((a & 0xFFF) << 16) | (b & 0xFFFF);
    }

    /// Bind a pattern against a value; false when the pattern cannot match
    /// a value built here with another constructor (a dead arm).
    fn bind(t: *Tokens, pat: u32, v: u32) Error!bool {
        try t.op();
        const d = t.data(pat);
        const x = t.vals.items[v];
        switch (t.tag(pat)) {
            .pat_wild, .pat_int, .pat_char, .pat_string, .pat_unit => return true,
            .pat_var => {
                const lv = if (try t.localHolds(d.lhs)) v else try t.noneVal();
                (try t.locals.getOrPut(t.gpa, .{d.lhs})).value_ptr.* = lv;
                return true;
            },
            .pat_as => {
                if (!try t.bind(d.lhs, v)) return false;
                const lv = if (try t.localHolds(d.rhs)) v else try t.noneVal();
                (try t.locals.getOrPut(t.gpa, .{d.rhs})).value_ptr.* = lv;
                return true;
            },
            .pat_ctor, .pat_tuple => {
                const key: u32 = if (t.tag(pat) == .pat_tuple) tuple_key else (t.ctorKey(d.lhs) orelse {
                    t.fail("pattern constructor");
                    return true;
                });
                const args = if (t.tag(pat) == .pat_tuple) t.bir().extraSlice(Bir.inlineRange(d), Bir.Inst.Index) else t.bir().extraSlice(t.bir().subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index);
                if (x.kind == .con) {
                    if (x.ctor != key) return false;
                    for (args, 0..) |a, i| {
                        const kv = if (i < x.kids.len) t.vkids.items[x.kids.start + i] else try t.noneVal();
                        if (!try t.bind(a.int(), kv)) return false;
                    }
                    return true;
                }
                for (args, 0..) |a, i| {
                    const kv = if (x.kind == .tok) try t.val(.{ .kind = .tok, .tok = try t.child(x.tok, stepWord(1, key, @intCast(i))) }) else try t.noneVal();
                    if (!try t.bind(a.int(), kv)) return false;
                }
                return true;
            },
            .pat_record => {
                for (t.bir().extraSlice(Bir.inlineRange(d), u32)) |local| {
                    const kv = if (x.kind == .tok and try t.localHolds(local)) try t.val(.{ .kind = .tok, .tok = try t.child(x.tok, stepWord(2, 0, local)) }) else if (x.kind == .con) blk: {
                        // A record built here: every field's tokens (its field order is not ours to read).
                        var occs: std.ArrayList(Occ) = .empty;
                        defer occs.deinit(t.gpa);
                        try t.flatten(v, 1, &occs);
                        break :blk try t.opq(occs.items, try t.isClean(v));
                    } else try t.noneVal();
                    (try t.locals.getOrPut(t.gpa, .{local})).value_ptr.* = kv;
                }
                return true;
            },
            .pat_list => {
                const items = t.bir().extraSlice(Bir.inlineRange(d), Bir.Inst.Index);
                var spread_seen = false;
                for (items, 0..) |a, i| {
                    const is_spread = t.tag(a.int()) == .pat_spread;
                    const step = if (is_spread) stepWord(3, 1, @intCast(i)) else stepWord(3, if (spread_seen) 2 else 0, @intCast(if (spread_seen) items.len - i else i));
                    if (is_spread) spread_seen = true;
                    const kv = switch (x.kind) {
                        .tok => try t.val(.{ .kind = .tok, .tok = try t.child(x.tok, step) }),
                        .con => blk: {
                            // A literal matched here: its elements, the spread a part of the list.
                            if (!is_spread and !spread_seen and i < x.kids.len) break :blk t.vkids.items[x.kids.start + i];
                            var occs: std.ArrayList(Occ) = .empty;
                            defer occs.deinit(t.gpa);
                            try t.flatten(v, 1, &occs);
                            break :blk try t.opq(occs.items, false);
                        },
                        .none => try t.noneVal(),
                    };
                    if (is_spread) {
                        if (!try t.bind(t.data(a.int()).lhs, kv)) return false;
                    } else if (!try t.bind(a.int(), kv)) return false;
                }
                return true;
            },
            .pat_spread => return t.bind(d.lhs, v),
            else => {
                t.fail("pattern");
                return true;
            },
        }
    }

    /// The value of an expression.
    fn eval(t: *Tokens, i: u32) Error!u32 {
        try t.op();
        const d = t.data(i);
        switch (t.tag(i)) {
            .local => return (t.locals.get(.{d.lhs})) orelse t.noneVal(),
            .int, .float, .char, .string, .chunk, .unit, .interp => return t.noneVal(),
            .ctor, .ext_ctor => {
                const key = t.ctorKey(i) orelse {
                    t.fail("constructor");
                    return t.noneVal();
                };
                return t.val(.{ .kind = .con, .ctor = key, .tok = if (try t.ownsCell(i)) try t.rootTok(.fresh, i) else none });
            },
            .top, .ext_value => {
                // A parameterless value: shared, never this activation's.
                if (!try t.instHolds(i)) return t.noneVal();
                return t.opq(&.{.{ .tok = try t.rootTok(.fresh, i), .mult = 2 }}, false);
            },
            .tuple, .list => {
                const items = t.bir().extraSlice(Bir.inlineRange(d), Bir.Inst.Index);
                const kids = try t.gpa.alloc(u32, items.len);
                defer t.gpa.free(kids);
                for (items, 0..) |e, k| kids[k] = try t.eval(e.int());
                const start: u32 = @intCast(t.vkids.items.len);
                try t.vkids.appendSlice(t.gpa, kids);
                return t.val(.{ .kind = .con, .ctor = if (t.tag(i) == .tuple) tuple_key else none, .tok = if (try t.ownsCell(i)) try t.rootTok(.fresh, i) else none, .kids = .{ .start = start, .len = @intCast(items.len) } });
            },
            .record => {
                const fields = t.bir().extraSlice(Bir.inlineRange(d), Bir.Field);
                const kids = try t.gpa.alloc(u32, fields.len);
                defer t.gpa.free(kids);
                for (fields, 0..) |f, k| kids[k] = try t.eval(f.value.int());
                const start: u32 = @intCast(t.vkids.items.len);
                try t.vkids.appendSlice(t.gpa, kids);
                return t.val(.{ .kind = .con, .ctor = none - 1, .tok = if (try t.ownsCell(i)) try t.rootTok(.fresh, i) else none, .kids = .{ .start = start, .len = @intCast(fields.len) } });
            },
            .field_access, .tuple_index => {
                const target = try t.eval(d.lhs);
                if (!try t.instHolds(i)) return t.noneVal();
                const x = t.vals.items[target];
                switch (x.kind) {
                    .none => return t.noneVal(),
                    .tok => return t.val(.{ .kind = .tok, .tok = try t.child(x.tok, if (t.tag(i) == .field_access) stepWord(2, 0, d.rhs) else stepWord(1, tuple_key, d.rhs)) }),
                    .con => {
                        if (t.tag(i) == .tuple_index and d.rhs < x.kids.len) return t.vkids.items[x.kids.start + d.rhs];
                        var occs: std.ArrayList(Occ) = .empty;
                        defer occs.deinit(t.gpa);
                        try t.flatten(target, 1, &occs);
                        return t.opq(occs.items, try t.isClean(target));
                    },
                }
            },
            .call, .method_call => return t.call(i),
            .let => {
                for (t.bir().extraSlice(t.bir().subRange(@fromBackingInt(d.lhs)), Bir.Inst.Index)) |b| try t.letItem(b.int());
                return t.eval(d.rhs);
            },
            .case => {
                const scrut = try t.eval(d.lhs);
                const branches = t.bir().extraSlice(t.bir().subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index);
                if (!try t.instHolds(i)) {
                    for (branches) |b| if (try t.bind(t.data(b.int()).lhs, scrut)) {
                        _ = try t.eval(t.data(b.int()).rhs);
                    };
                    return t.noneVal();
                }
                // A choice: the larger multiplicity per token, over the arms.
                var all: std.ArrayList(Occ) = .empty;
                defer all.deinit(t.gpa);
                var clean = true;
                for (branches) |b| {
                    if (!try t.bind(t.data(b.int()).lhs, scrut)) continue;
                    const v = try t.eval(t.data(b.int()).rhs);
                    var occs: std.ArrayList(Occ) = .empty;
                    defer occs.deinit(t.gpa);
                    try t.flatten(v, 1, &occs);
                    if (!try t.isClean(v)) clean = false;
                    for (occs.items) |o| {
                        var merged = false;
                        for (all.items) |*a| if (a.tok == o.tok) {
                            a.mult = @max(a.mult, o.mult);
                            merged = true;
                        };
                        if (!merged) try all.append(t.gpa, o);
                    }
                }
                return t.opq(all.items, clean);
            },
            .@"error" => {
                t.fail("error");
                return t.noneVal();
            },
            else => {
                t.fail(@tagName(t.tag(i)));
                return t.noneVal();
            },
        }
    }

    fn letItem(t: *Tokens, b: u32) Error!void {
        const d = t.data(b);
        switch (t.tag(b)) {
            .let_def => {
                const def = t.bir().extraData(@fromBackingInt(d.lhs), Bir.LetDef);
                if (def.params_end != def.params_start) {
                    t.fail("local function");
                    return;
                }
                const v = try t.eval(d.rhs);
                const lv = if (try t.localHolds(def.local)) v else try t.noneVal();
                (try t.locals.getOrPut(t.gpa, .{def.local})).value_ptr.* = lv;
            },
            .let_pattern => _ = try t.bind(d.lhs, try t.eval(d.rhs)),
            .let_stmt => _ = try t.eval(d.rhs),
            else => t.fail("let item"),
        }
    }

    /// The values a body can return, one per tail arm: a tail `case`'s arms
    /// are alternatives, counted apart (the maximum).
    fn tails(t: *Tokens, i: u32, out: *std.ArrayList(u32)) Error!void {
        try t.op();
        const d = t.data(i);
        switch (t.tag(i)) {
            .let => {
                for (t.bir().extraSlice(t.bir().subRange(@fromBackingInt(d.lhs)), Bir.Inst.Index)) |b| try t.letItem(b.int());
                try t.tails(d.rhs, out);
            },
            .case => {
                const scrut = try t.eval(d.lhs);
                for (t.bir().extraSlice(t.bir().subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index)) |b| {
                    if (!try t.bind(t.data(b.int()).lhs, scrut)) continue;
                    try t.tails(t.data(b.int()).rhs, out);
                }
            },
            else => try out.append(t.gpa, try t.eval(i)),
        }
    }

    /// A call's value: a constructor's built node, else an opaque value
    /// whose expansion is the callee's multiplicities over the arguments.
    fn call(t: *Tokens, i: u32) Error!u32 {
        const d = t.data(i);
        var args: std.ArrayList(u32) = .empty;
        defer args.deinit(t.gpa);
        try t.mod.argsOf(i, &args);
        const vs = try t.gpa.alloc(u32, args.items.len);
        defer t.gpa.free(vs);
        for (args.items, 0..) |a, k| vs[k] = try t.eval(a);
        if (t.tag(i) == .call) if (t.ctorKey(d.lhs)) |key| {
            const start: u32 = @intCast(t.vkids.items.len);
            try t.vkids.appendSlice(t.gpa, vs);
            return t.val(.{ .kind = .con, .ctor = key, .tok = if (try t.ownsCell(i)) try t.rootTok(.fresh, i) else none, .kids = .{ .start = start, .len = @intCast(vs.len) } });
        };
        if (!try t.instHolds(i)) return t.noneVal();
        const cand = try t.calleeCand(i, vs.len);
        if (tok_trace) std.debug.print("tok call {d}: mults {any} fdup {}\n", .{ i, cand.mults, cand.fresh_dup });
        var exp: std.ArrayList(Occ) = .empty;
        defer exp.deinit(t.gpa);
        var clean = !cand.fresh_dup;
        for (vs, 0..) |v, k| {
            const m: u2 = if (k < cand.mults.len) cand.mults[k] else 2;
            if (m > 1) clean = false;
            try t.flatten(v, m, &exp);
        }
        if (clean) {
            // The arguments together repeat no object.
            var occs: std.ArrayList(Occ) = .empty;
            defer occs.deinit(t.gpa);
            for (vs, 0..) |v, k| if (k < cand.mults.len and cand.mults[k] != 0) try t.flatten(v, 1, &occs);
            try t.resolve(&occs);
            var dummy: [0]u2 = .{};
            var fd = false;
            if (!try t.count(occs.items, &dummy, &fd) or fd) clean = false;
        }
        try exp.append(t.gpa, .{ .tok = try t.rootTok(.fresh, i), .mult = if (cand.fresh_dup) 2 else 1 });
        return t.opq(exp.items, clean);
    }

    var unknown_mults: [32]u2 = @splat(2);

    /// The callee's multiplicities: the group's candidate for a member, the
    /// predicate of another declaration of this module analysed on demand,
    /// else read off its v2 class (a parameter the answer reaches at most one
    /// non-summary path of is once; one it never reaches, zero), else
    /// repeated.
    fn calleeCand(t: *Tokens, i: u32, nargs: usize) Error!Cand {
        const unknown: Cand = .{ .mults = unknown_mults[0..@min(nargs, 32)], .fresh_dup = true };
        const target = t.mod.calledDecl(i) orelse return t.classCand(i, nargs, unknown);
        if (target[0] == t.mod.in.module) {
            if (t.mod.group) |g| if (g.index.get(.{target[1]})) |k| return t.cand[k];
            if (t.cache.get(target[1])) |c| return c;
            if (try t.analyseDecl(target[1])) |c| return c;
        }
        return t.classCand(i, nargs, unknown);
    }

    fn classCand(t: *Tokens, i: u32, nargs: usize, unknown: Cand) Error!Cand {
        const saved = t.mod.group;
        t.mod.group = null;
        const ce = Module.callee(t.mod, i) catch |err| {
            t.mod.group = saved;
            return err;
        };
        t.mod.group = saved;
        const cls = switch (ce) {
            .class => |c| c,
            .harmless => {
                const m = try t.gpa.alloc(u2, nargs);
                @memset(m, 0);
                try t.cache_mults.append(t.gpa, m);
                return .{ .mults = m, .fresh_dup = false };
            },
            else => return unknown,
        };
        const m = try t.gpa.alloc(u2, nargs);
        try t.cache_mults.append(t.gpa, m);
        @memset(m, 0);
        const c = t.mod.sums.get(cls);
        var on_path: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer on_path.deinit(t.gpa);
        var fd = false;
        var budget: u32 = 4096;
        const counts = try t.countRes(c.res, c.kappas, false, .none, null, nargs, &on_path, &fd, &budget) orelse return unknown;
        defer t.gpa.free(counts);
        for (m, counts) |*x, n| x.* = sat(n);
        return .{ .mults = m, .fresh_dup = fd };
    }

    /// Per parameter, how many positions of a callee's answer may hold one of
    /// its objects: a position counts once where the class's κ there is not
    /// `lost`/`shared` (its objects are apart, conditionally on the caller's
    /// separation, which the token analysis assumes too), twice otherwise;
    /// coexisting parts add, alternatives take the larger; a cycle of the
    /// answer repeats whatever it reaches. Null: a shape this reader does
    /// not cover (unknown).
    fn countRes(t: *Tokens, n: Ids.NodeId, kpos: Cond.Kappas, at_summary: bool, parent: Ids.SetId, step: ?Step, nargs: usize, on_path: *std.AutoHashMapUnmanaged(u32, void), fd: *bool, budget: *u32) Error!?[]u32 {
        if (budget.* == 0) return null;
        budget.* -= 1;
        try t.op();
        const gpa = t.gpa;
        const out = try gpa.alloc(u32, nargs);
        @memset(out, 0);
        errdefer gpa.free(out);
        const mod = t.mod;
        const env = mod.env();
        if (on_path.contains(n.int())) {
            var it = mod.cells.sets.iterate(try mod.shapes.reach(gpa, mod.account, &mod.cells.sets, n));
            while (it.next()) |e| switch (mod.cells.origin(.from(e.key))) {
                .param => {
                    const pi = mod.cells.get(.from(e.key)).a;
                    if (pi < nargs) out[pi] = 2;
                },
                .result, .site => fd.* = true,
                else => {},
            };
            return out;
        }
        try on_path.put(gpa, n.int(), {});
        defer _ = on_path.remove(n.int());
        const node = mod.shapes.get(n);
        switch (node.kind) {
            .leaf, .node => {
                const k = try env.conds.kappaOf(gpa, env.charge, env.view(), kpos, n, at_summary);
                const bad = k == Cond.lost or k == Cond.shared;
                var it = mod.cells.sets.iterate(try mod.shapes.cellsOf(gpa, mod.account, &mod.cells.sets, n));
                while (it.next()) |e| switch (mod.cells.origin(.from(e.key))) {
                    .param => {
                        const pc = mod.cells.get(.from(e.key));
                        const pi = pc.a;
                        // The parent position's object projected by this step:
                        // the same occurrence, not another.
                        const q: Ids.PathId = .from(pc.b);
                        const projected = if (step) |st| blk: {
                            const p0 = mod.places.pathParent(q);
                            if (p0 == .none or !Step.eql(mod.places.pathStep(q), st)) break :blk false;
                            const up = try mod.cells.symbolic(gpa, mod.account, &mod.places, .param, pi, p0, 0);
                            break :blk mod.cells.sets.member(parent, up.int());
                        } else false;
                        if (pi < nargs and (!projected or bad)) out[pi] += if (bad) 2 else 1;
                    },
                    .result, .site, .esc => if (bad) {
                        fd.* = true;
                    },
                    .top, .shared => {},
                    else => {
                        gpa.free(out);
                        return null;
                    },
                };
                if (node.kind == .node) {
                    var oi = mod.shapes.overEntries(node.a);
                    while (oi.next()) |e| {
                        const below = mod.places.kind(node.place) == .list or mod.places.kind(node.place) == .dict or at_summary;
                        const sub = (try t.countRes(e.node, mod.conds.kappaChild(kpos, e.step), below, try mod.shapes.cellsOf(gpa, mod.account, &mod.cells.sets, n), e.step, nargs, on_path, fd, budget)) orelse {
                            gpa.free(out);
                            return null;
                        };
                        defer gpa.free(sub);
                        for (out, sub) |*o, s| o.* += s;
                    }
                }
            },
            .@"union", .choice, .positions => {
                const l = (try t.countRes(.from(node.a), kpos, at_summary, parent, step, nargs, on_path, fd, budget)) orelse {
                    gpa.free(out);
                    return null;
                };
                defer gpa.free(l);
                const r = (try t.countRes(.from(node.b), kpos, at_summary, parent, step, nargs, on_path, fd, budget)) orelse {
                    gpa.free(out);
                    return null;
                };
                defer gpa.free(r);
                for (out, l, r) |*o, x, y| o.* = if (node.kind == .positions) x + y else @max(x, y);
            },
            else => {
                gpa.free(out);
                return null;
            },
        }
        return out;
    }

    /// A same-module declaration outside the group, analysed once: its
    /// predicate with no hypothesis (a recursive one met here is unknown).
    fn analyseDecl(t: *Tokens, di: u32) Error!?Cand {
        if (t.busy.contains(di)) return null;
        const d = t.bir().decls[di];
        if (d.body.unwrap() == null) return null;
        try t.busy.put(t.gpa, di, {});
        defer _ = t.busy.remove(di);
        const saved_locals = t.locals;
        t.locals = .{};
        const saved_cur = t.mod.cur_locals;
        t.mod.cur_locals = d.locals_start;
        defer {
            t.locals.deinit(t.gpa);
            t.locals = saved_locals;
            t.mod.cur_locals = saved_cur;
        }
        const saved_failed = t.failed;
        t.failed = null;
        const m = try t.gpa.alloc(u2, d.params);
        try t.cache_mults.append(t.gpa, m);
        @memset(m, 0);
        var fd = false;
        try t.body(di, m, &fd);
        const failed = t.failed;
        t.failed = saved_failed;
        if (failed != null) return null;
        const c: Cand = .{ .mults = m, .fresh_dup = fd };
        try t.cache.put(t.gpa, di, c);
        return c;
    }

    /// One evaluation of a declaration's body: the multiplicities its tail
    /// arms reach, joined into `mults` and `fd` (the maximum).
    fn body(t: *Tokens, di: u32, mults: []u2, fd: *bool) Error!void {
        const d = t.bir().decls[di];
        const params = t.bir().extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index);
        for (params, 0..) |p, k| {
            const v = try t.val(.{ .kind = .tok, .tok = try t.rootTok(.param, @intCast(k)) });
            _ = try t.bind(p.int(), v);
        }
        var outs: std.ArrayList(u32) = .empty;
        defer outs.deinit(t.gpa);
        const b = d.body.unwrap() orelse return;
        try t.tails(b.int(), &outs);
        for (outs.items) |o| {
            var occs: std.ArrayList(Occ) = .empty;
            defer occs.deinit(t.gpa);
            try t.flatten(o, 1, &occs);
            try t.resolve(&occs);
            if (tok_trace) for (occs.items) |oc| std.debug.print("tok tail {d}: tok {d} root {t} arg {d} depth {d} mult {d}\n", .{ di, oc.tok, t.root_kind.items[t.root.items[oc.tok]], t.root_arg.items[t.root.items[oc.tok]], t.depth.items[oc.tok], oc.mult });
            _ = try t.count(occs.items, mults, fd);
        }
    }
};

/// Stage 2: the least fixed point of the group's multiplicities from 0, then
/// one validation pass against it; a member the validator refuses, or whose
/// body the analysis does not cover, publishes stage 1's κ.
fn inferTokens(mod: *Module, g: *Group, cs: []Contract, rs: []DeclResult) Error!void {
    const gpa = mod.gpa;
    var t: Tokens = .{ .gpa = gpa, .mod = mod };
    defer t.deinit();
    const n = g.members.len;
    const cand = try gpa.alloc(Tokens.Cand, n);
    defer {
        for (cand) |c| gpa.free(c.mults);
        gpa.free(cand);
    }
    for (cand, 0..) |*c, k| {
        c.mults = try gpa.alloc(u2, g.param_runs.items[k].len);
        @memset(c.mults, 0);
        c.fresh_dup = false;
    }
    t.cand = cand;
    // A test-only mutation: claim the strongest predicate with no inference,
    // so the validator alone must refuse a false one.
    const forced = mod.in.contracts == 3 or mod.in.contracts == 4;
    var failed: ?[]const u8 = null;
    if (forced) {
        for (cand) |*c| @memset(c.mults, 1);
    } else while (true) {
        var moved = false;
        for (g.members, 0..) |di, k| {
            charging(mod, &rs[k].account);
            t.failed = null;
            const m = try gpa.alloc(u2, cand[k].mults.len);
            defer gpa.free(m);
            @memcpy(m, cand[k].mults);
            var fd = cand[k].fresh_dup;
            t.locals.deinit(gpa);
            t.locals = .{};
            mod.cur_locals = mod.in.bir.decls[di].locals_start;
            try t.body(di, m, &fd);
            if (t.failed) |f| failed = f;
            if (!std.mem.eql(u2, m, cand[k].mults) or fd != cand[k].fresh_dup) {
                @memcpy(cand[k].mults, m);
                cand[k].fresh_dup = fd;
                moved = true;
            }
        }
        for (cs) |*c| c.stats.token_rounds += 1;
        if (!moved) break;
    }
    const infer_ops = t.ops;
    // Validation: each body once more under the candidate, nothing reused
    // from the inference but the candidate itself.
    for (g.members, 0..) |di, k| {
        charging(mod, &rs[k].account);
        var vt: Tokens = .{ .gpa = gpa, .mod = mod, .cand = cand };
        defer vt.deinit();
        const m = try gpa.alloc(u2, cand[k].mults.len);
        defer gpa.free(m);
        @memset(m, 0);
        var fd = false;
        mod.cur_locals = mod.in.bir.decls[di].locals_start;
        try vt.body(di, m, &fd);
        var ok = vt.failed == null and failed == null;
        for (m, cand[k].mults) |got, claimed| if (got > claimed) {
            ok = false;
        };
        if (fd and !cand[k].fresh_dup) ok = false;
        const c = &cs[k];
        c.stats.validate_ops = vt.ops;
        c.stats.token_ops = infer_ops;
        c.stats.tokens = @intCast(t.parent.items.len + vt.parent.items.len);
        c.stats.validated = ok;
        @memcpy(c.mults, cand[k].mults);
        c.fresh_dup = cand[k].fresh_dup;
        // Preserved: validated, and some parameter is not repeated.
        c.preserved = ok or mod.in.contracts == 4;
        if (vt.failed orelse failed) |f| c.stats.reason = f else if (!ok) c.stats.reason = "validator refused the candidate";
    }
}
