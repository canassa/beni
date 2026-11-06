//! L10: the module (`docs/design/ownership-v2.md` §2.1, §2.11, §2.12, §5):
//! the source and signature adapters, the module's codes, each call's
//! callee, and the solving of every declaration group.
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
//! **Codes** (§2.10): a walked declaration's body, each of its lambdas and
//! local functions (their captures after their own parameters), and each
//! function a reference names as a value (its contract fixed: words, an
//! import, a constructor's, a schema member's). A code's contract is its
//! candidate while its group is solved, then its final one.
//!
//! **A group** (§2.12): every member's codes are walked once; the codes are
//! evaluated, their contracts read off and joined into their candidates,
//! until no evaluation read a candidate that moved after it; the last
//! round's evaluations, under the settled candidates, are the verdicts.
//!
//! Obligations kept here: none of §2.14's directly; the adapter's places
//! are what O6's "`⟲` covers every level" folds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Rows = @import("Rows.zig");
const Worded = @import("Worded.zig");
const Prepass = @import("Prepass.zig");
const Regions = @import("Regions.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Eval = @import("Eval.zig");
const ReadOff = @import("ReadOff.zig");
const Walk = @import("Walk.zig");
const Resolve = @import("Resolve.zig");
const Kept = @import("Kept.zig");
const Deliver = @import("Deliver.zig");
const Closures = @import("Closures.zig");
const Once = @import("Once.zig");
const Called = @import("Called.zig");
const CodeCaps = @import("CodeCaps.zig");
const TypeVarParam = @import("TypeVarParam.zig");
const CondsOff = @import("CondsOff.zig");
const Answers = @import("Answers.zig");
const Contents = @import("Contents.zig");
const Within = @import("Within.zig");
const Outward = @import("Outward.zig");
const EntryHeld = @import("EntryHeld.zig");
const FnRun = @import("FnRun.zig");
const Codes = @import("Codes.zig");
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const stamped = @import("../stamped.zig");
const Ast = @import("../parse/Ast.zig");

pub const PlaceId = Ids.PlaceId;
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
    /// Per module, whether it is in the core package.
    core: []const bool = &.{},
    /// Symbol text, to name a type's `eq`/`compare`.
    interner: ?*const InternPool.Global = null,
    /// The imports' published contracts (§3.6), or none.
    imports: ?Imports = null,

    pub fn isCore(in: *const Input, m: u32) bool {
        return m < in.core.len and in.core[m];
    }
};

/// How a module reads another's contracts (§3.6): module `m`'s block
/// decoded into `mod`'s tables, per declaration of `m` its contract or
/// `none`; null when `m` publishes no block, or one that does not decode
/// (R-5.7.4: an unknown summary).
pub const Imports = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, mod: *Module, m: u32) Error!?[]u32,
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
    /// `nominal`: a non-regular type folded onto this node (`applied`).
    fold: bool = false,
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
    fn cons(a: *Adapter, head: u32, tail: u32) Ids.IndexError!u32 {
        const got = try a.lists.getOrPut(a.gpa, .{ head, tail });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(a.list_cells.items.len);
            try a.list_cells.append(a.gpa, .{ head, tail });
        }
        return got.value_ptr.*;
    }

    fn listOf(a: *Adapter, ids: []const u32) Ids.IndexError!u32 {
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
    fn structural(a: *Adapter, k: Place.Kind, head: u32, kids: []const Kid) Ids.IndexError!u32 {
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

    fn nominal(a: *Adapter, t: Types.TypeId, args: []const u32, origin: u32) Ids.IndexError!u32 {
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
    pub fn rank(a: *const Adapter, s: InternPool.Symbol) u32 {
        const i = @backingInt(s);
        if (i >= a.in.ranks.len) @panic("ownership v2: a symbol interned after the ranks were taken");
        return a.in.ranks[i];
    }

    // ---- store variables -----------------------------------------------------

    /// The id of store variable `v`: post-order over its structure on an explicit stack, each root once.
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
            const id = try a.close(c, &kids, &ids);
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

    /// The id of a child read while its parent closes: its own, or the knot of a variable still open (a cycle).
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

    fn close(a: *Adapter, c: TypeStore.Content, kids: *std.ArrayList(Kid), ids: *std.ArrayList(u32)) Error!u32 {
        const store = a.in.store;
        switch (c) {
            .flex, .rigid => |fl| return if (fl.kind.scalar()) a.leaf(&a.cross_id, .cross) else a.leaf(&a.var_id, .@"var"), // `[ 0 ]` is `List number`: no object
            .err, .alias => return a.leaf(&a.var_id, .@"var"),
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
            const id = try a.nominal(t, vars, within);
            a.nodes.items[id].fold = true;
            return id;
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

    /// Read once a walk is over: a type folds onto a node after the node's place is made.
    fn folded(ctx: *anyopaque, id: u32) bool {
        const a: *Adapter = @ptrCast(@alignCast(ctx));
        return a.nodes.items[id].fold;
    }

    fn describe(ctx: *anyopaque, id: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const a: *Adapter = @ptrCast(@alignCast(ctx));
        return a.describeOr(id, out) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // A limit met while describing: the node is a leaf that may hold
            // anything; the account has the failure and stops the owner.
            else => blk: {
                if (err == error.ProbeLength) _ = a.account.probeFailed();
                break :blk .{ .kind = .@"var" };
            },
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
        if (e.schema_endpoint) return .{ .kind = .@"var" };
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
        return .{ .ctx = a, .describe = describe, .folded = folded };
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
        if (q != p and !try @import("PlaceIdentity.zig").equals(places, p, places, q, a.gpa, .growth(a.account), &own.proven)) return null;
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

pub const DeclResult = Codes.DeclResult;
pub const CodeKind = Codes.CodeKind;
pub const Code = Codes.Code;

pub const Module = struct {
    in: *const Input,
    gpa: Allocator,
    places: Place.Table = .{},
    slots: Slots.Table = .{},
    contracts: Contract.Table = .{},
    adapter: Adapter,
    /// The account being charged.
    account: *Ids.Account,
    base_account: Ids.Account = .{},
    results: std.ArrayList(DeclResult) = .empty,
    result_of: []u32 = &.{},
    prepass_arena: std.heap.ArenaAllocator,
    /// The walks' arena: every walk of the module, kept until it is published.
    walk_arena: std.heap.ArenaAllocator,
    prepass: Facts.Prepass = undefined,
    /// The local index the walked declaration's locals start at.
    cur_locals: u32 = 0,
    codes: std.ArrayList(Code) = .empty,
    code_places: std.ArrayList(PlaceId) = .empty,
    code_caps: std.ArrayList(u32) = .empty,
    /// Per declaration: its body code, or `none`.
    body_code: []u32 = &.{},
    /// Lambdas', local functions' and references' codes by instruction.
    code_of_inst: Ids.FixedDict(1) = .{},
    /// `(body code, function slot)` → its called code (§2.11.3).
    called_index: Ids.FixedDict(2) = .{},
    /// The count of `called_index` a declaration stops at (§2.11.3, *Which slots*).
    called_cap: u32 = 0,
    /// Imported declarations passed as evidence: their codes by `(module, declaration)`.
    evidence_code: Ids.FixedDict(2) = .{},
    /// Per imported module read: its contracts by declaration.
    imported: stamped.Column(u32, ?[]u32) = .{},
    /// Each read's cost, by module (§4.1, *A module table's entries*).
    import_cost: Ids.Costs = .{},
    imported_owned: std.ArrayList([]u32) = .empty,
    comparison: []bool = &.{},
    cmp_decl: []u32 = &.{},
    /// Codes read by the evaluation under way: `(code, version)`.
    reads: std.ArrayList([2]u32) = .empty,
    /// The pessimistic contract by arity at `2·arity`, a `foreign`'s at `+1`.
    pessimistic_of: std.ArrayList(u32) = .empty,
    /// Worded contracts by declaration and places (§4.1, #1714).
    worded: Worded.Worded = .{},
    /// The imports' blocks read, and the modules whose block was missing or did not round-trip (§3.6).
    imports_read: u32 = 0,
    imports_unknown: std.ArrayList(u32) = .empty,

    pub fn deinit(mod: *Module) void {
        const gpa = mod.gpa;
        for (mod.codes.items) |c| if (c.walk) |w| w.deinit();
        mod.places.deinit(gpa);
        mod.slots.deinit(gpa);
        mod.contracts.deinit(gpa);
        mod.adapter.deinit();
        for (mod.results.items) |*r| r.account.deinit(gpa);
        mod.results.deinit(gpa);
        gpa.free(mod.result_of);
        gpa.free(mod.comparison);
        gpa.free(mod.body_code);
        mod.prepass_arena.deinit();
        mod.walk_arena.deinit();
        mod.base_account.deinit(gpa);
        mod.codes.deinit(gpa);
        mod.code_places.deinit(gpa);
        mod.code_caps.deinit(gpa);
        mod.code_of_inst.deinit(gpa);
        mod.called_index.deinit(gpa);
        mod.evidence_code.deinit(gpa);
        for (mod.imported_owned.items) |cs| gpa.free(cs);
        mod.imported_owned.deinit(gpa);
        mod.imported.deinit(gpa);
        mod.import_cost.deinit(gpa);
        gpa.free(mod.cmp_decl);
        mod.reads.deinit(gpa);
        mod.pessimistic_of.deinit(gpa);
        mod.worded.deinit(gpa);
        mod.imports_unknown.deinit(gpa);
    }

    pub fn rowsEnv(mod: *Module, arena: Allocator) Rows.Env {
        return .{ .gpa = mod.gpa, .arena = arena, .account = mod.account, .places = &mod.places, .slots = &mod.slots, .contracts = &mod.contracts };
    }

    /// The contract declaration `di` of module `m` publishes, read from `m`'s block at the first need.
    fn importedContract(mod: *Module, m: u32, di: u32) Error!?u32 {
        const imports = mod.in.imports orelse return null;
        if (!mod.imported.contains(m)) {
            const a = mod.account;
            const fill = a.beginFill();
            const cs = imports.read(imports.ctx, mod, m) catch |err| {
                _ = a.endFill(fill);
                return err;
            };
            try mod.import_cost.put(mod.gpa, m, a.endFill(fill));
            if (cs) |c| mod.imported_owned.append(mod.gpa, c) catch |err| {
                mod.gpa.free(c);
                return err;
            };
            try mod.imported.put(mod.gpa, m, cs);
            mod.imports_read += 1;
            if (cs == null) try mod.imports_unknown.append(mod.gpa, m);
        }
        try mod.account.readEntry(mod.gpa, .import, m, mod.import_cost.get(m));
        const cs = mod.imported.get(m).? orelse return null;
        return if (di < cs.len and cs[di] != none) cs[di] else null;
    }

    // ---- what a walk reads ----------------------------------------------------

    fn self(ctx: *anyopaque) *Module {
        return @ptrCast(@alignCast(ctx));
    }

    pub fn placeOfInst(ctx: *anyopaque, inst: u32) Error!PlaceId {
        const mod = self(ctx);
        const v: Var.Optional = if (inst < mod.in.inst_type.len) mod.in.inst_type[inst] else .none;
        return mod.adapter.placeOfVar(v);
    }

    pub fn placeOfLocal(ctx: *anyopaque, local: u32) Error!PlaceId {
        const mod = self(ctx);
        const v: Var.Optional = if (mod.cur_locals + local < mod.in.local_type.len) mod.in.local_type[mod.cur_locals + local] else .none;
        return mod.adapter.placeOfVar(v);
    }

    fn fieldRank(ctx: *anyopaque, s: Bir.SymbolIndex) u32 {
        const mod = self(ctx);
        return mod.adapter.rank(mod.in.bir.symbol(s));
    }

    pub fn fieldRankOf(mod: *Module, s: InternPool.Symbol) u32 {
        return mod.adapter.rank(s);
    }

    /// The `(module, decl)` a value reference names, or null.
    pub fn declOfCtx(ctx: *anyopaque, inst: u32) ?[2]u32 {
        return self(ctx).declOf(inst);
    }

    /// The `(module, decl)` a callee reference runs, aliases followed (R-5.5.6).
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

    /// A function value declared with no parameters (`f = λx → …`): its
    /// lambda's code, which a call runs (never the declaration's own code,
    /// whose answer is the closure).
    fn lambdaBody(mod: *const Module, di: u32) ?u32 {
        const b = mod.in.bir.decls[di].body.unwrap() orelse return null;
        if (mod.in.bir.instTag(b) != .lambda) return null;
        return mod.code_of_inst.get(.{b.int()});
    }

    pub fn aliasTarget(mod: *const Module, t: [2]u32) [2]u32 {
        return Prepass.aliasTarget(mod.in.birs, mod.in.provenance, t);
    }

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

    /// The `(module, constructor index)` a constructor reference names.
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

    /// A constructor reference's `(ordinal, arity)`.
    fn ctorOf(ctx: *anyopaque, ref: u32) ?[2]u32 {
        const mod = self(ctx);
        const at = ctorIndexCtx(mod, ref) orelse return null;
        const owner = mod.in.birs[at[0]];
        const c = owner.ctors[at[1]];
        const decl = owner.decl(c.decl);
        return .{ at[1] - decl.ctors_start, @backingInt(c.args_end) - @backingInt(c.args_start) };
    }

    fn ctorField(ctx: *anyopaque, ref: u32, n: u32) ?u32 {
        const mod = self(ctx);
        const at = ctorIndexCtx(mod, ref) orelse return null;
        const owner = mod.in.birs[at[0]];
        const body = owner.decl(owner.ctors[at[1]].decl).annotation.unwrap() orelse return null;
        if (owner.decl(owner.ctors[at[1]].decl).kind != .type_alias or owner.instTag(body) != .type_record) return null;
        const fields = owner.extraSlice(Bir.inlineRange(owner.instData(body)), Bir.Field);
        return if (n < fields.len) mod.adapter.rank(owner.symbol(fields[n].name)) else null;
    }

    fn sharedOf(ctx: *anyopaque, ref: u32) ?[2]u32 {
        const mod = self(ctx);
        const md = mod.declOf(ref) orelse return null;
        const decl = mod.in.birs[md[0]].decls[md[1]];
        if ((decl.kind != .value and decl.kind != .foreign_value) or decl.params != 0) return null;
        const at = placeOfInst(ctx, ref) catch return null;
        if (mod.places.kind(at) == .closure) return null;
        if (decl.kind == .foreign_value) return .{ none, 0 };
        // A value whose contract holds no object (`Dict.empty`) is no shared object (§2.3.3).
        const c = if (md[0] != mod.in.module) mod.importedContract(md[0], md[1]) catch null else if (md[1] < mod.body_code.len and mod.body_code[md[1]] != none) contractOf(ctx, mod.body_code[md[1]]) else null;
        return if (c != null and mod.contracts.holdsNothing(c.?)) .{ none, 1 } else md;
    }

    pub fn isListAppend(ctx: *anyopaque, inst: u32) bool {
        const mod = self(ctx);
        const dt = mod.in.dispatch orelse return false;
        return dt.isListAppend(@fromBackingInt(inst)) or dt.isListAppend(@fromBackingInt(mod.in.bir.instData(@fromBackingInt(inst)).lhs));
    }

    fn isSequence(mod: *const Module, at: PlaceId) bool {
        return mod.places.kind(at) == .list and mod.places.child(at, Step.elem) != null;
    }

    fn isCell(mod: *const Module, at: PlaceId) bool {
        return mod.places.kind(at) == .ref and mod.places.child(at, Step.contents) != null;
    }

    fn pessimisticOf(mod: *Module, arity: u32, host: bool) Error!u32 {
        const at = 2 * arity + @intFromBool(host);
        while (mod.pessimistic_of.items.len <= at) try mod.pessimistic_of.append(mod.gpa, none);
        if (mod.pessimistic_of.items[at] == none) {
            var arena: std.heap.ArenaAllocator = .init(mod.gpa);
            defer arena.deinit();
            mod.pessimistic_of.items[at] = try Rows.pessimistic(mod.rowsEnv(arena.allocator()), arity, host);
        }
        return mod.pessimistic_of.items[at];
    }

    fn pessimistic(ctx: *anyopaque, arity: u32) Error!Contract.Id {
        return self(ctx).pessimisticOf(arity, false);
    }

    /// The places of a function type: its parameters' and its result's.
    fn fnPlaces(mod: *Module, v: Var.Optional, params: *std.ArrayList(PlaceId)) Error!?PlaceId {
        const t = v.unwrap() orelse return null;
        switch (mod.in.store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .func => |f| {
                    for (mod.in.store.vars(f.params)) |p| try params.append(mod.gpa, try mod.adapter.placeOfVar(p.toOptional()));
                    return try mod.adapter.placeOfVar(f.result.toOptional());
                },
                else => {},
            },
            else => {},
        }
        return null;
    }

    /// A worded declaration's contract over the given places.
    fn wordedContract(mod: *Module, owner: u32, di: u32, params: []const PlaceId, result: PlaceId) Error!u32 {
        const k = try mod.worded.find(mod.gpa, mod.account, .{ owner, di, @backingInt(result) }, params);
        if (k.contract) |c| return c;
        const fill = mod.account.beginFill();
        const c = mod.wordedFill(owner, di, params, result) catch |err| {
            _ = mod.account.endFill(fill);
            return err;
        };
        try mod.worded.put(mod.gpa, mod.account, k.run, c, mod.account.endFill(fill));
        return c;
    }

    fn wordedFill(mod: *Module, owner: u32, di: u32, params: []const PlaceId, result: PlaceId) Error!u32 {
        const decl = mod.in.birs[owner].decls[di];
        var arena: std.heap.ArenaAllocator = .init(mod.gpa);
        defer arena.deinit();
        const words = mod.in.birs[owner].ownSlotsV2(decl);
        var ps: std.ArrayList(Rows.Param) = .empty;
        defer ps.deinit(mod.gpa);
        var result_words: u32 = 0;
        for (params, 0..) |at, k| {
            var w: u32 = 0;
            for (words) |s| if (s[0] == k) {
                w = s[1];
            };
            // An `entry` without the state protocol is no word: escaped (R-5.8.1).
            const names: Prepass.EntryNames = if (mod.in.interner) |i| .{ .update = i.find("update"), .settle = i.find("settle") } else .{ .update = null, .settle = null };
            if (w & Ast.OwnWord.entry.bit() != 0 and !Prepass.entryProtocol(mod.in.birs[owner], decl, k, names)) w = 0;
            try ps.append(mod.gpa, .{ .place = at, .words = w, .type_variable = try TypeVarParam.paramIsTypeVariable(mod.in, owner, decl, k) });
        }
        for (words) |s| if (s[0] == Bir.own_result) {
            result_words = s[1];
        };
        return Rows.fromWords(mod.rowsEnv(arena.allocator()), .{ .params = ps.items, .result = result, .result_words = result_words, .origin = .{ owner, di }, .foreign = decl.kind == .foreign_value });
    }

    /// The contract of declaration `t` (another module's, or this one's when worded) over a use's places, or null.
    fn declContract(mod: *Module, t: [2]u32, params: []const PlaceId, result: PlaceId) Error!?u32 {
        const owner = mod.in.birs[t[0]];
        const decl = owner.decls[t[1]];
        if (owner.ownSlotsV2(decl).len != 0) return try mod.wordedContract(t[0], t[1], params, result);
        // A `foreign` publishes nothing an importer applies: its words, or none (§2.10).
        if (decl.kind == .foreign_value) return try mod.pessimisticOf(@intCast(params.len), true);
        if (t[0] == mod.in.module) return null;
        if (try mod.importedContract(t[0], t[1])) |c| return c;
        return null;
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

    /// The local function a `.local` reference names, as its code.
    fn localFunction(mod: *Module, ref: u32) ?u32 {
        const bir = mod.in.bir;
        if (bir.instTag(@fromBackingInt(ref)) != .local) return null;
        const l = bir.instData(@fromBackingInt(ref)).lhs;
        const binding = bir.locals[mod.cur_locals + l].inst.int();
        if (bir.instTag(@fromBackingInt(binding)) != .let_def) return null;
        return mod.code_of_inst.get(.{binding});
    }

    fn callee(ctx: *anyopaque, inst: u32, args: []const u32) Error!Walk.Callee {
        const mod = self(ctx);
        const bir = mod.in.bir;
        var target: ?[2]u32 = null;
        var composed = false;
        if (bir.instTag(@fromBackingInt(inst)) == .call) {
            const head = bir.instData(@fromBackingInt(inst)).lhs;
            if (ctorOf(ctx, head)) |c| return .{ .ctor = c };
            if (mod.localFunction(head)) |c| return .{ .code = c };
            target = mod.declOf(head);
        } else if (mod.in.dispatch) |dt| if (dt.siteOf(@fromBackingInt(inst))) |site| if (site.callee.unwrap()) |ti| {
            switch (dt.term(ti)) {
                .top => |u| target = .{ mod.in.module, u.decl.int() },
                .ext => |u| if (mod.in.provenance.len > u.module.int()) if (mod.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| {
                    target = .{ u.module.int(), d.int() };
                },
                // A record field of function type: its value, called (§2.11.5).
                .field => return .field,
                .param, .codec => {},
                else => composed = true,
            }
        };
        // Every argument and the result cross: nothing to track.
        var harmless = !Slots.holdsAny(&mod.places, try mod.places.rootPath(mod.gpa, try placeOfInst(ctx, inst)));
        for (args) |x| harmless = harmless and !Slots.holdsAny(&mod.places, try mod.places.rootPath(mod.gpa, try placeOfInst(ctx, x)));
        // A function value is never harmless: its code may write what its
        // closure holds, a label of the frame (§2.11.3).
        if (harmless and (target != null or composed)) return .harmless;
        var ps: std.ArrayList(PlaceId) = .empty;
        defer ps.deinit(mod.gpa);
        for (args) |x| try ps.append(mod.gpa, try placeOfInst(ctx, x));
        const result = try placeOfInst(ctx, inst);
        if (target) |t0| {
            const t = mod.aliasTarget(t0);
            if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none) {
                if (mod.in.bir.decls[t[1]].params == 0 and args.len != 0) return if (mod.lambdaBody(t[1])) |c| .{ .code = c } else .{ .contract = try mod.pessimisticOf(@intCast(args.len), false) };
                // A container's comparison in core is its components'.
                if (!(mod.in.isCore(t[0]) and bir.instTag(@fromBackingInt(inst)) == .method_call and composedOrigin(bir, inst))) return .{ .code = mod.body_code[t[1]] };
            }
            if (try mod.declContract(t, ps.items, result)) |c| return .{ .contract = c };
            // An imported alias: the contract a module publishes under a
            // name of the chain (R-5.5.6).
            var n = t0;
            var hops: usize = 64;
            while (hops > 0 and !std.mem.eql(u32, &n, &t)) : (hops -= 1) {
                if (n[0] != mod.in.module) if (try mod.importedContract(n[0], n[1])) |c| return .{ .contract = c };
                n = Prepass.aliasStep(mod.in.birs, mod.in.provenance, n) orelse break;
            }
            if (bir.instTag(@fromBackingInt(inst)) == .method_call and mod.in.isCore(t[0]) and composedOrigin(bir, inst)) composed = true;
            if (!composed) return .{ .contract = try mod.pessimisticOf(@intCast(args.len), false) };
        }
        if (composed) {
            var arena: std.heap.ArenaAllocator = .init(mod.gpa);
            defer arena.deinit();
            return .{ .contract = try Rows.comparison(mod.rowsEnv(arena.allocator()), @intCast(args.len)) };
        }
        if (bir.instTag(@fromBackingInt(inst)) == .method_call) return .{ .contract = try mod.pessimisticOf(@intCast(args.len), false) };
        return .value;
    }

    fn composedOrigin(bir: *const Bir, inst: u32) bool {
        const m = bir.extraData(@fromBackingInt(@intCast(bir.instData(@fromBackingInt(inst)).rhs)), Bir.MethodCall);
        return m.origin != .none;
    }

    /// A function reference used as a value: its code (§2.11.4).
    fn funcRef(ctx: *anyopaque, inst: u32) Error!?u32 {
        const mod = self(ctx);
        const bir = mod.in.bir;
        if (mod.code_of_inst.get(.{inst})) |c| return c;
        const tag = bir.instTag(@fromBackingInt(inst));
        var ps: std.ArrayList(PlaceId) = .empty;
        defer ps.deinit(mod.gpa);
        const v: Var.Optional = if (inst < mod.in.inst_type.len) mod.in.inst_type[inst] else .none;
        const result = (try mod.fnPlaces(v, &ps)) orelse return null;
        var arena: std.heap.ArenaAllocator = .init(mod.gpa);
        defer arena.deinit();
        var contract: u32 = none;
        switch (tag) {
            .ctor, .ext_ctor => {
                const c = ctorOf(ctx, inst) orelse return null;
                var rp: std.ArrayList(Rows.Param) = .empty;
                defer rp.deinit(mod.gpa);
                var ranks: std.ArrayList(u32) = .empty;
                defer ranks.deinit(mod.gpa);
                for (ps.items, 0..) |p, n| {
                    try rp.append(mod.gpa, .{ .place = p });
                    if (ctorField(ctx, inst, @intCast(n))) |r| try ranks.append(mod.gpa, r);
                }
                contract = try Rows.ctor(mod.rowsEnv(arena.allocator()), .{ .params = rp.items, .result = result }, c[0], ranks.items);
            },
            // A member answers what its `via` conversions answer (a top-level
            // list, say), and a constructor holds its arguments: neither is
            // fresh, so neither has a row here (§2.13.10).
            .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor => contract = try mod.pessimisticOf(@intCast(ps.items.len), false),
            .top, .ext_value => {
                const t = mod.aliasTarget(mod.declOf(inst) orelse return null);
                if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none and (ps.items.len == 0 or mod.in.bir.decls[t[1]].params != 0)) {
                    try mod.code_of_inst.put(mod.gpa, .{inst}, mod.body_code[t[1]]);
                    return mod.body_code[t[1]];
                }
                if (t[0] == mod.in.module and t[1] < mod.body_code.len and mod.body_code[t[1]] != none) if (mod.lambdaBody(t[1])) |c| return c;
                contract = (try mod.declContract(t, ps.items, result)) orelse try mod.pessimisticOf(@intCast(ps.items.len), false);
            },
            else => return null,
        }
        const id: u32 = @intCast(mod.codes.items.len);
        const pstart: u32 = @intCast(mod.code_places.items.len);
        try mod.code_places.appendSlice(mod.gpa, ps.items);
        try mod.codes.append(mod.gpa, .{ .kind = .ref, .inst = inst, .params = .{ .start = pstart, .len = @intCast(ps.items.len) }, .own = @intCast(ps.items.len), .result = result, .contract = contract });
        try mod.code_of_inst.put(mod.gpa, .{inst}, id);
        return id;
    }

    /// The codes of the declarations a dispatch site at `inst` passes as
    /// evidence, every term however deep, each once (§2.11.4: a function
    /// value handed to code the checker does not see).
    fn evidenceCodes(ctx: *anyopaque, inst: u32, out: *std.ArrayList(u32)) Error!void {
        const mod = self(ctx);
        const dt = mod.in.dispatch orelse return;
        const site = dt.siteOf(@fromBackingInt(inst)) orelse return;
        var todo: std.ArrayList(Dispatch.TermIndex) = .empty;
        defer todo.deinit(mod.gpa);
        try todo.appendSlice(mod.gpa, dt.argsAt(site.evidence));
        var seen: std.ArrayList(Dispatch.TermIndex) = .empty;
        defer seen.deinit(mod.gpa);
        while (todo.pop()) |ti| {
            if (std.mem.indexOfScalar(Dispatch.TermIndex, seen.items, ti) != null) continue;
            try seen.append(mod.gpa, ti);
            try todo.appendSlice(mod.gpa, dt.argsOfTerm(ti));
            const t0: [2]u32 = switch (dt.term(ti)) {
                .top => |u| .{ mod.in.module, u.decl.int() },
                .ext => |u| if (mod.in.provenance.len > u.module.int()) if (mod.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| .{ u.module.int(), d.int() } else continue else continue,
                else => continue,
            };
            // A type's `eq` or `compare` writes nothing in place (R-5.13.1
            // refuses its writes), and a comparison composes it (§2.13.13).
            const name = mod.in.birs[t0[0]].symbol(mod.in.birs[t0[0]].decls[t0[1]].name);
            if (name == InternPool.WellKnown.eq.symbol() or name == InternPool.WellKnown.compare.symbol()) continue;
            const t = mod.aliasTarget(t0);
            if (t[0] == mod.in.module) {
                if (t[1] >= mod.body_code.len or mod.body_code[t[1]] == none) continue;
                const c = if (mod.in.bir.decls[t[1]].params != 0) mod.body_code[t[1]] else mod.lambdaBody(t[1]) orelse continue;
                if (std.mem.indexOfScalar(u32, out.items, c) == null) try out.append(mod.gpa, c);
                continue;
            }
            // Another module's: its published contract (a worded row writes
            // only where its own call site is authorised, never through a
            // function value).
            const owner = mod.in.birs[t[0]];
            if (owner.ownSlotsV2(owner.decls[t[1]]).len != 0) continue;
            const got = try mod.evidence_code.getOrPut(mod.gpa, .{ t[0], t[1] });
            if (!got.found_existing) {
                const contract = (try mod.importedContract(t[0], t[1])) orelse none;
                got.value_ptr.* = @intCast(mod.codes.items.len);
                try mod.codes.append(mod.gpa, .{ .kind = .ref, .inst = inst, .own = owner.decls[t[1]].params, .contract = contract });
            }
            if (std.mem.indexOfScalar(u32, out.items, got.value_ptr.*) == null) try out.append(mod.gpa, got.value_ptr.*);
        }
    }

    fn codeOf(ctx: *anyopaque, inst: u32) ?u32 {
        return self(ctx).code_of_inst.get(.{inst});
    }

    fn capturesOf(ctx: *anyopaque, code: u32) []const u32 {
        const mod = self(ctx);
        const c = mod.codes.items[code];
        return mod.code_caps.items[c.captures.start..][0..c.captures.len];
    }

    fn contractOf(ctx: *anyopaque, code: u32) ?Contract.Id {
        const mod = self(ctx);
        const c = mod.codes.items[code];
        if (c.contract == none) return null;
        if (c.kind != .ref) try_read: {
            mod.reads.append(mod.gpa, .{ code, c.version }) catch break :try_read;
        }
        return c.contract;
    }

    fn calledOf(ctx: *anyopaque, code: u32, rel: u32) ?u32 {
        return self(ctx).called_index.get(.{ code, rel });
    }

    fn codeSig(ctx: *anyopaque, code: u32) Error!Relation.Sig {
        const mod = self(ctx);
        const c = mod.codes.items[code];
        return .{ .params = mod.code_places.items[c.params.start..][0..c.params.len], .own = c.own, .result = c.result };
    }

    fn siteSig(ctx: *anyopaque, inst: u32, params: *std.ArrayList(PlaceId)) Error!?PlaceId {
        const mod = self(ctx);
        const v: Var.Optional = if (inst < mod.in.inst_type.len) mod.in.inst_type[inst] else .none;
        return mod.fnPlaces(v, params);
    }

    /// The function type a label's callee has at its origin, the callback
    /// call `f x` of this module (`siteSig` of its head), or null: an
    /// origin with a mark (`RowEnv.taken_origin`), another module's, or no
    /// call's (§2.11.3, #1758).
    fn originSig(ctx: *anyopaque, origin: [3]u32, params: *std.ArrayList(PlaceId)) Error!?PlaceId {
        const mod = self(ctx);
        const bir = mod.in.bir;
        if (origin[0] != mod.in.module or origin[1] >= bir.decls.len or origin[2] >= Called.last_origin) return null;
        // A worded row's labels (cells, `taken`, an `aliased` callback) name
        // no instruction: only a walked declaration's origin is a call.
        if (origin[1] >= mod.body_code.len or mod.body_code[origin[1]] == none) return null;
        const d = bir.decls[origin[1]];
        const i = d.inst_start.int() + origin[2];
        if (i >= d.inst_end.int() or bir.instTag(@fromBackingInt(i)) != .call) return null;
        return siteSig(ctx, bir.instData(@fromBackingInt(i)).lhs, params);
    }

    fn settledParam(ctx: *anyopaque, f: *Value.Frame, v: u32) Error!?[2]u32 {
        return FnRun.settled(f, &self(ctx).contracts, self(ctx).context(), v);
    }

    /// A `try`'s shape (§2.11.5): `(success, failure, failure arity)` ordinals of its scrutinee's type, `Ok`/`Err` or `Just`/`Nothing`.
    fn tryShape(ctx: *anyopaque, inst: u32) ?[3]u32 {
        const mod = self(ctx);
        const scrut = mod.in.bir.instData(@fromBackingInt(inst)).lhs;
        const at = placeOfInst(ctx, scrut) catch return null;
        if (mod.places.kind(at) != .ctor) return null;
        const head = mod.places.head(at);
        if (head >= mod.in.types.entries.len) return null;
        const wk = mod.in.types.well_known;
        if (head == wk.result.int()) return .{ 0, 1, 1 };
        if (head == wk.maybe.int()) return .{ 0, 1, 0 };
        return null;
    }

    pub fn context(mod: *Module) Walk.Context {
        return .{
            .ctx = mod,
            .placeOfInst = placeOfInst,
            .placeOfLocal = placeOfLocal,
            .fieldRank = fieldRank,
            .ctorOf = ctorOf,
            .ctorField = ctorField,
            .sharedOf = sharedOf,
            .isListAppend = isListAppend,
            .callee = callee,
            .funcRef = funcRef,
            .evidenceCodes = evidenceCodes,
            .codeOf = codeOf,
            .capturesOf = capturesOf,
            .contractOf = contractOf,
            .calledOf = calledOf,
            .codeSig = codeSig,
            .siteSig = siteSig,
            .originSig = originSig,
            .settledParam = settledParam,
            .pessimistic = pessimistic,
            .tryShape = tryShape,
        };
    }

    /// The contract of declaration `di`'s body when it is done and within its limits; null otherwise.
    pub fn walkedContract(mod: *const Module, di: u32) ?u32 {
        if (di >= mod.result_of.len) return null;
        if (mod.result_of[di] == none) {
            const d = mod.in.bir.decls[di];
            if (!Prepass.isAliasShape(mod.in.bir, d) or !isFunctionScheme(mod.in, di)) return null;
            const t = mod.aliasTarget(.{ mod.in.module, di });
            if (t[0] != mod.in.module or t[1] == di or mod.result_of[t[1]] == none) return null;
            return mod.walkedContract(t[1]);
        }
        const r = mod.results.items[mod.result_of[di]];
        if (r.failure != null or r.contract == none) return null;
        return r.contract;
    }
};

// ---------------------------------------------------------------------------
// Checking a module
// ---------------------------------------------------------------------------

pub fn checkModule(in: *const Input, mod: *Module) Allocator.Error!void {
    try initModule(in, mod);
    mod.prepass = try Prepass.run(in.gpa, mod.prepass_arena.allocator(), .{ .bir = in.bir, .dispatch = in.dispatch });
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(in.gpa);
    // Every walked declaration has a body code before any is solved: a call
    // of a later group's is never made (groups come in dependency order).
    for (0..in.bir.decls.len) |di| if (isWalked(in, @intCast(di))) {
        mod.body_code[di] = @intCast(mod.codes.items.len);
        try mod.codes.append(in.gpa, .{ .kind = .body, .decl = @intCast(di) });
    };
    for (0..mod.prepass.starts.len - 1) |gi| {
        try groupMembers(in.gpa, in, &mod.prepass, gi, null, &members);
        if (members.items.len == 0) continue;
        const first: u32 = @intCast(mod.results.items.len);
        for (members.items) |di| {
            mod.result_of[di] = @intCast(mod.results.items.len);
            var acc: Ids.Account = .{ .allowance = allowanceOf(in.bir, di) };
            acc.source = in.bir.decls[di].inst_end.int() - in.bir.decls[di].inst_start.int();
            try mod.results.append(in.gpa, .{ .decl = di, .account = acc });
        }
        defer for (mod.results.items[first..]) |*r| r.account.dropFirsts(in.gpa);
        solveGroup(mod, mod.results.items[first..]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OwnershipLimit, error.AccountingInvariant, error.ProbeLength => {
                for (mod.results.items[first..]) |*r| {
                    if (r.account.failed == null) r.account.failed = if (err == error.ProbeLength) .{ .limit = .probe_length } else .{ .exhausted = .other };
                    r.failure = r.account.failed;
                    r.lines = &.{};
                    r.contract = none;
                    const bc = mod.body_code[r.decl];
                    charging(mod, &mod.base_account);
                    for (mod.codes.items) |*c| if (c.kind == .called and c.of == bc) {
                        c.contract = none;
                    };
                    mod.codes.items[bc].contract = mod.pessimisticOf(in.bir.decls[r.decl].params, false) catch |e2| switch (e2) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => none,
                    };
                }
            },
        };
    }
    mod.account = &mod.base_account;
    mod.adapter.account = &mod.base_account;
}

fn initModule(in: *const Input, mod: *Module) Allocator.Error!void {
    mod.* = .{
        .in = in,
        .gpa = in.gpa,
        .adapter = undefined,
        .account = undefined,
        .prepass_arena = .init(in.gpa),
        .walk_arena = .init(in.gpa),
    };
    mod.account = &mod.base_account;
    mod.adapter = .{ .in = in, .gpa = in.gpa, .places = &mod.places, .account = &mod.base_account };
    mod.result_of = try in.gpa.alloc(u32, in.bir.decls.len);
    @memset(mod.result_of, none);
    mod.body_code = try in.gpa.alloc(u32, in.bir.decls.len);
    @memset(mod.body_code, none);
    mod.comparison = try comparisonWalks(in);
}

/// `mod` charging `account` from here on.
pub fn charging(mod: *Module, account: *Ids.Account) void {
    mod.account = account;
    mod.adapter.account = account;
}

/// The codes of declaration `di`: its body, then its lambdas and local functions, with their captures (§2.11.4).
fn declCodes(mod: *Module, di: u32, out: *std.ArrayList(u32)) Error!void {
    const in = mod.in;
    const bir = in.bir;
    const gpa = mod.gpa;
    const d = bir.decls[di];
    const fr = mod.prepass.enclosing_frame;
    const start = d.inst_start.int();
    const n = d.inst_end.int() - start;
    try out.append(gpa, mod.body_code[di]);
    {
        var ps: std.ArrayList(PlaceId) = .empty;
        defer ps.deinit(gpa);
        const result = try declPlaces(mod, d, di, &ps);
        const c = &mod.codes.items[mod.body_code[di]];
        const pstart: u32 = @intCast(mod.code_places.items.len);
        try mod.code_places.appendSlice(gpa, ps.items);
        c.params = .{ .start = pstart, .len = @intCast(ps.items.len) };
        c.own = @intCast(ps.items.len);
        c.result = result;
        c.inst = none;
        try calledCodes(mod, di, ps.items, out);
    }
    // The nested codes, innermost first (a lambda's body before it).
    var nested: std.ArrayList(u32) = .empty;
    defer nested.deinit(gpa);
    var i = start;
    while (i < d.inst_end.int()) : (i += 1) {
        const tag = bir.instTag(@fromBackingInt(i));
        const is_code = tag == .lambda or (tag == .let_def and blk: {
            const def = bir.extraData(@fromBackingInt(bir.instData(@fromBackingInt(i)).lhs), Bir.LetDef);
            break :blk def.params_end != def.params_start;
        });
        if (!is_code) continue;
        const id: u32 = @intCast(mod.codes.items.len);
        try mod.codes.append(gpa, .{ .kind = if (tag == .lambda) .lambda else .local, .decl = di, .inst = i });
        try mod.code_of_inst.put(gpa, .{i}, id);
        try nested.append(gpa, i);
        try out.append(gpa, id);
    }
    if (nested.items.len == 0) return;
    var caps: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (caps.items) |*c| c.deinit(gpa);
        caps.deinit(gpa);
    }
    try CodeCaps.of(gpa, bir, d, fr, nested.items, &caps);
    mod.cur_locals = d.locals_start;
    for (nested.items, 0..) |c, k| {
        std.mem.sort(u32, caps.items[k].items, {}, std.sort.asc(u32));
        const id = mod.code_of_inst.get(.{c}).?;
        const tag = bir.instTag(@fromBackingInt(c));
        const dd = bir.instData(@fromBackingInt(c));
        const params: []const Bir.Inst.Index, const body: u32 = if (tag == .lambda)
            .{ bir.extraSlice(bir.subRange(@fromBackingInt(dd.lhs)), Bir.Inst.Index), dd.rhs }
        else blk: {
            const def = bir.extraData(@fromBackingInt(dd.lhs), Bir.LetDef);
            break :blk .{ bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index), dd.rhs };
        };
        const pstart: u32 = @intCast(mod.code_places.items.len);
        // A pattern's own type is not recorded: its place is the parameter's in the code's function type.
        var fps: std.ArrayList(PlaceId) = .empty;
        defer fps.deinit(gpa);
        const fl = if (tag == .lambda) c else mod.cur_locals + bir.extraData(@fromBackingInt(dd.lhs), Bir.LetDef).local;
        const typed = (try mod.fnPlaces(if (tag == .lambda and fl < mod.in.inst_type.len) mod.in.inst_type[fl] else if (tag != .lambda and fl < mod.in.local_type.len) mod.in.local_type[fl] else .none, &fps)) != null and fps.items.len == params.len;
        for (params, 0..) |p, pi| try mod.code_places.append(gpa, if (bir.instTag(p) == .pat_var) try Module.placeOfLocal(mod, bir.instData(p).lhs) else if (typed) fps.items[pi] else try Module.placeOfInst(mod, p.int()));
        for (caps.items[k].items) |l| try mod.code_places.append(gpa, try Module.placeOfLocal(mod, l));
        const cstart: u32 = @intCast(mod.code_caps.items.len);
        try mod.code_caps.appendSlice(gpa, caps.items[k].items);
        const code = &mod.codes.items[id];
        code.params = .{ .start = pstart, .len = @intCast(params.len + caps.items[k].items.len) };
        code.own = @intCast(params.len);
        code.captures = .{ .start = cstart, .len = @intCast(caps.items[k].items.len) };
        code.result = try Module.placeOfInst(mod, body);
    }
    _ = n;
}

/// The called codes of declaration \`di\`'s body, of parameters \`params\`: one per
/// function slot of its result, at \`ε\` and through records and tuples
/// (§2.11.3, *Which slots*).
fn calledCodes(mod: *Module, di: u32, params: []const PlaceId, out: *std.ArrayList(u32)) Error!void {
    const scheme: Var.Optional = if (di < mod.in.decl_scheme.len) mod.in.decl_scheme[di] else .none;
    const v = scheme.unwrap() orelse return;
    const f = switch (mod.in.store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .func => |f| f,
            else => return,
        },
        else => return,
    };
    if (mod.in.store.vars(f.params).len != params.len) return;
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(mod.gpa);
    mod.called_cap = mod.called_index.count() + @as(u32, @intCast(Slots.below_min));
    try funcSlots(mod, f.result, di, params, &words, out);
}

fn funcSlots(mod: *Module, t: Var, di: u32, params: []const PlaceId, words: *std.ArrayList(u32), out: *std.ArrayList(u32)) Error!void {
    const gpa = mod.gpa;
    const s = switch (mod.in.store.resolvedContent(t)) {
        .structure => |x| x,
        else => return,
    };
    // Each slot is a walk of the body, and a tuple of tuples doubles its slots.
    if (!mod.places.holds(try mod.adapter.placeOfVar(t.toOptional())).closure or mod.called_index.count() >= mod.called_cap) return;
    switch (s) {
        .func => {
            const pstart: u32 = @intCast(mod.code_places.items.len);
            var own: std.ArrayList(PlaceId) = .empty;
            defer own.deinit(gpa);
            const result = (try mod.fnPlaces(t.toOptional(), &own)) orelse return;
            try mod.code_places.appendSlice(gpa, own.items);
            try mod.code_places.appendSlice(gpa, params);
            try mod.code_places.append(gpa, try mod.adapter.placeOfVar(t.toOptional()));
            const id: u32 = @intCast(mod.codes.items.len);
            const rel = try mod.slots.relOfWords(gpa, mod.account, &mod.places, words.items);
            try mod.codes.append(gpa, .{ .kind = .called, .decl = di, .of = mod.body_code[di], .slot = rel, .params = .{ .start = pstart, .len = @intCast(mod.code_places.items.len - pstart) }, .own = @intCast(own.items.len), .result = result });
            try mod.called_index.put(gpa, .{ mod.body_code[di], rel }, id);
            try out.append(gpa, id);
        },
        .tuple => |r| for (mod.in.store.vars(r), 0..) |e, k| {
            try words.append(gpa, (try Place.Step.index(mod.account, @intCast(k))).word());
            defer _ = words.pop();
            try funcSlots(mod, e, di, params, words, out);
        },
        .record => |rec| {
            // The fields along the extension chain, by rank: the cap stops at the same ones in any build.
            var kids: std.ArrayList([2]u32) = .empty;
            defer kids.deinit(gpa);
            var at = rec;
            while (true) {
                for (mod.in.store.fields(at.fields)) |fld| try kids.append(gpa, .{ (try Place.Step.field(mod.account, mod.adapter.rank(fld.name))).word(), @backingInt(fld.value) });
                switch (mod.in.store.resolvedContent(at.ext)) {
                    .structure => |es| switch (es) {
                        .record => |next| at = next,
                        else => break,
                    },
                    else => break,
                }
            }
            std.mem.sort([2]u32, kids.items, {}, struct {
                fn lt(_: void, x: [2]u32, y: [2]u32) bool {
                    return x[0] < y[0];
                }
            }.lt);
            for (kids.items) |kid| {
                try words.append(gpa, kid[0]);
                defer _ = words.pop();
                try funcSlots(mod, @fromBackingInt(kid[1]), di, params, words, out);
            }
        },
        else => {},
    }
}

/// The code's walk input.
fn walkCode(mod: *Module, id: u32) Error!Walk.Code {
    const c = mod.codes.items[id];
    const bir = mod.in.bir;
    const d = bir.decls[c.decl];
    const places = mod.code_places.items[c.params.start..][0..c.params.len];
    if (c.kind == .called) {
        var w = try walkCode(mod, c.of);
        w.called = .{ .own_places = places[0..c.own], .words = try mod.walk_arena.allocator().dupe(u32, mod.slots.relWords(c.slot)), .body_result = w.result_place };
        w.result_place = c.result;
        return w;
    }
    if (c.kind == .body) return .{ .decl = d, .decl_index = c.decl, .inst = none, .params = bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index), .param_places = places, .captures = &.{}, .body = d.body.unwrap().?.int(), .result_place = c.result };
    const dd = bir.instData(@fromBackingInt(c.inst));
    const params: []const Bir.Inst.Index, const body: u32 = if (c.kind == .lambda)
        .{ bir.extraSlice(bir.subRange(@fromBackingInt(dd.lhs)), Bir.Inst.Index), dd.rhs }
    else blk: {
        const def = bir.extraData(@fromBackingInt(dd.lhs), Bir.LetDef);
        break :blk .{ bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index), dd.rhs };
    };
    return .{ .decl = d, .decl_index = c.decl, .inst = c.inst, .params = params, .param_places = places, .captures = mod.code_caps.items[c.captures.start..][0..c.captures.len], .body = body, .result_place = c.result };
}

/// Solve one group (§2.12): walk every code of its members once, evaluate
/// them until no evaluation read a candidate that moved after it, and keep
/// the last round's verdicts.
fn solveGroup(mod: *Module, rs: []DeclResult) Error!void {
    const gpa = mod.gpa;
    const in = mod.in;
    var codes: std.ArrayList(u32) = .empty;
    defer codes.deinit(gpa);
    var owner: std.ArrayList(u32) = .empty;
    defer owner.deinit(gpa);
    var regions: std.ArrayList(Regions.Tree) = .empty;
    defer {
        for (regions.items) |*t| t.deinit(gpa);
        regions.deinit(gpa);
    }
    const arena = mod.walk_arena.allocator();
    for (rs, 0..) |*r, k| {
        charging(mod, &r.account);
        mod.cur_locals = in.bir.decls[r.decl].locals_start;
        const before = codes.items.len;
        try declCodes(mod, r.decl, &codes);
        for (codes.items[before..]) |_| try owner.append(gpa, @intCast(k));
        try regions.append(gpa, try Regions.build(gpa, &r.account, .inference, in.bir, in.bir.decls[r.decl], &mod.prepass));
    }
    // One walk per code (§2.12): nested codes first, so a closure's code
    // exists before the frame that makes it.
    var atoms = try gpa.alloc(u32, rs.len);
    defer gpa.free(atoms);
    @memset(atoms, 0);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    for (rs, 0..) |_, k| {
        var x = codes.items.len;
        while (x > 0) {
            x -= 1;
            if (owner.items[x] == k) try order.append(gpa, @intCast(x));
        }
    }
    for (order.items) |x| {
        const id = codes.items[x];
        const r = &rs[owner.items[x]];
        charging(mod, &r.account);
        mod.cur_locals = in.bir.decls[r.decl].locals_start;
        const w = try arena.create(Walk.Walk);
        try Walk.walk(gpa, arena, &r.account, &mod.places, &mod.slots, &regions.items[owner.items[x]], &mod.prepass, in.bir, in.module, mod.context(), &mod.contracts, try walkCode(mod, id), &atoms[owner.items[x]], w);
        mod.codes.items[id].walk = w;
        if (mod.codes.items[id].kind != .called) r.walks += 1;
    }
    // Every code of the group starts at ⊥ (§2.12).
    var bot: Contract.Draft = .{ .arity = 0 };
    for (codes.items) |id| {
        const c = &mod.codes.items[id];
        bot.arity = c.params.len;
        c.contract = try mod.contracts.commit(gpa, &rs[0].account, &mod.slots, &bot);
    }
    // Rounds of evaluations, until nothing moved after it was read.
    var round: u32 = 0;
    var lines: std.ArrayList(std.ArrayList(Resolve.Line)) = .empty;
    defer {
        for (lines.items) |*l| l.deinit(gpa);
        lines.deinit(gpa);
    }
    for (rs) |_| try lines.append(gpa, .empty);
    // Inference rounds deliver facts between the members (§2.12 step 2), their judgements
    // kept across rounds; then a validation round evaluates each code once more, plainly,
    // under the candidates, and its verdicts are the lines (step 3).
    var validating = false;
    var kg = try Kept.Group.init(gpa, order.items.len);
    defer kg.deinit(gpa);
    while (true) : (round += 1) {
        for (lines.items) |*l| l.clearRetainingCapacity();
        mod.reads.clearRetainingCapacity();
        var moved = false;
        var round_arena: std.heap.ArenaAllocator = .init(gpa);
        defer round_arena.deinit();
        const ra = round_arena.allocator();
        // One evaluation per code, all open at once: a member's facts are
        // delivered to the codes that read them as they come (§2.12 step 2).
        const n = order.items.len;
        const evals = try ra.alloc(Eval.Evaluation, n);
        const drafts = try ra.alloc(Contract.Draft, n);
        const ids = try ra.alloc(u32, n);
        for (order.items, 0..) |x, i| ids[i] = codes.items[x];
        for (drafts, ids) |*d, id| d.* = .{ .arity = mod.codes.items[id].params.len };
        var solver: Deliver.Solver = undefined;
        try solver.init(gpa, ids, evals, drafts);
        defer solver.deinit();
        const sv: ?*Deliver.Solver = if (validating) null else &solver;
        var opened: usize = 0;
        defer for (evals[0..opened]) |*e| e.deinit();
        for (order.items, 0..) |x, i| {
            const r = &rs[owner.items[x]];
            charging(mod, &r.account);
            mod.cur_locals = in.bir.decls[r.decl].locals_start;
            try Eval.evaluate(mod.codes.items[ids[i]].walk.?, &mod.contracts, mod.context(), ra, if (sv) |v| &v.group else null, @intCast(i), &evals[i]);
            opened += 1;
            try Once.demands(&evals[i]);
        }
        for (order.items, 0..) |x, i| {
            const r = &rs[owner.items[x]];
            charging(mod, &r.account);
            mod.cur_locals = in.bir.decls[r.decl].locals_start;
            try ReadOff.factsOff(&evals[i], ra, &drafts[i]);
            try Contents.check(&evals[i], ra, &drafts[i]);
            if (sv) |v| try v.pump();
        }
        if (!validating and solver.used) try kg.round(gpa, &rs[0].account, &mod.contracts, mod.codes.items, ids, drafts, evals);
        for (order.items, 0..) |x, i| {
            const id = ids[i];
            const k = owner.items[x];
            const r = &rs[k];
            charging(mod, &r.account);
            mod.cur_locals = in.bir.decls[r.decl].locals_start;
            const e = &evals[i];
            const called = mod.codes.items[id].kind == .called;
            if (!called) try EntryHeld.demands(e);
            try Outward.finishDemands(e);
            if (!called) for ([_]bool{ false, true }) |w| if (w) try Closures.escapedWrites(e) else try @import("ClosureRuns.zig").labels(e);
            const got = try Resolve.resolve(e, &regions.items[k], ra, if (validating or !solver.used) null else &kg.tables[i]);
            // R-5.13.1: in a comparison's walk, a write of what arrived is `comparison_changes_value`;
            // a write of a fresh value stays accepted, and the contract keeps its writes (§2.13.13 item 13).
            if (mod.comparison[r.decl]) for (got.lines) |*l| {
                if (l.outcome.verdict == .accepted and l.outcome.accepted == .param) {
                    l.outcome.verdict = .refused;
                    l.outcome.cause = .comparison;
                }
            };
            try CondsOff.condsOff(e, ra, got.verdicts, Answers.groupRecurses(evals, ids));
            const c = try mod.contracts.commit(gpa, &r.account, &mod.slots, &drafts[i]);
            const code = &mod.codes.items[id];
            if (validating) {
                // Not within its candidate: an inference defect, joined and
                // validated again (§2.12 step 3), never silent.
                if (try Within.within(&mod.contracts, ra, &mod.slots, c, code.contract)) {
                    // Within: the code's own contract is what it does under the candidates, so it is
                    // what callers read (no reliance a round of the inference made and a later one dropped).
                    code.contract = c;
                } else {
                    code.contract = try mod.contracts.join(gpa, ra, &r.account, &mod.slots, code.contract, c);
                    code.version += 1;
                    moved = true;
                    rs[k].defects += 1;
                }
            } else {
                const next = try mod.contracts.join(gpa, ra, &r.account, &mod.slots, code.contract, c);
                if (!mod.contracts.eql(next, code.contract)) {
                    code.contract = next;
                    code.version += 1;
                    moved = true;
                }
            }
            if (!called) for (got.lines) |l| try lines.items[k].append(gpa, l);
        }
        // Settled when every read saw the version that stands now.
        var stale = false;
        for (mod.reads.items) |rd| if (mod.codes.items[rd[0]].version != rd[1]) {
            stale = true;
        };
        if (validating) {
            if (!moved) break;
        } else if (!stale or !moved) {
            // A round in which no code read another's draft was a plain evaluation already: its
            // verdicts stand (a code with no recursion is evaluated once).
            if (!solver.used) break;
            validating = true;
        }
        if (round > 4096) return error.OwnershipLimit;
    }
    for (codes.items) |id| if (mod.codes.items[id].kind == .called) {
        const c = mod.codes.items[id];
        try mod.contracts.putCalled(gpa, mod.codes.items[c.of].contract, c.slot, c.contract);
    };
    for (rs, lines.items) |*r, *l| {
        r.rounds = round + 1;
        r.contract = mod.codes.items[mod.body_code[r.decl]].contract;
        // The lines outlive the walks: the demands' texts read the BIR only.
        r.lines = try arena.dupe(Resolve.Line, l.items);
        std.mem.sort(Resolve.Line, r.lines, {}, struct {
            fn lt(_: void, a: Resolve.Line, b: Resolve.Line) bool {
                if (a.demand.point != b.demand.point) return a.demand.point < b.demand.point;
                return a.demand.base_inst < b.demand.base_inst;
            }
        }.lt);
    }
}

/// The contract a declaration of this module publishes (§3.6): its body's,
/// or a worded one's words over its scheme, or the pessimistic one of a
/// `foreign` without words; null for no value, or one stopped by a limit.
pub fn declaredContract(mod: *Module, di: u32) Error!?u32 {
    const d = mod.in.bir.decls[di];
    if (!d.kind.isValue()) return null;
    if (mod.result_of[di] != none) {
        const r = mod.results.items[mod.result_of[di]];
        return if (r.failure != null) null else r.contract;
    }
    if (mod.walkedContract(di)) |c| return c;
    const scheme: Var.Optional = if (di < mod.in.decl_scheme.len) mod.in.decl_scheme[di] else .none;
    var ps: std.ArrayList(PlaceId) = .empty;
    defer ps.deinit(mod.gpa);
    const result = (try mod.fnPlaces(scheme, &ps)) orelse try mod.adapter.placeOfVar(scheme);
    if (mod.in.bir.ownSlotsV2(d).len != 0) return try mod.wordedFill(mod.in.module, di, ps.items, result);
    if (d.kind == .foreign_value) return try mod.pessimisticOf(@intCast(ps.items.len), true);
    return null;
}

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

/// R_f (§4.4): the declaration's `@ownership_summary_size`, else the module's, else the default.
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
