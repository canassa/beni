//! Instantiation (checker-v2.md §4.2, §6.6): copying a generalised
//! type into the current frame, and building the type a reference names.
//!
//! **The rank and the pool are explicit**: everything made
//! here is made at the current frame's rank and joins its young pool, so the
//! boundary adjusts and generalises it like any other variable.
//!
//! **`copy` is iterative**: no walk stops at a fixed depth without
//! reporting, so a deep scheme is never silently shared with its copy. A
//! first pass allocates
//! one fresh variable per generalised node reachable from the scheme (the
//! memo is the descriptor's `copy` field, so sharing survives: `(y, y)`
//! copies `y` once) and a second fills each copy's content with its
//! children mapped through the memo. A node that is not generalised is
//! shared, as in Elm: that is what keeps a lambda parameter monomorphic.
//! Constraint method types are successors (`Walk.owned`) and so
//! are copied through the same memo (§4.2), and each requirement the copy
//! makes becomes a wanted of the instantiating instruction (one per
//! requirement, `want`) — as does each requirement an imported scheme is
//! read with.
//!
//! **What a reference names** is resolved from the module's own Bir or a
//! dependency's INTERFACE, never a dependency's Bir (`fast-compiler.md`
//! §8.1). `.local` and `.top` are not here: the generator resolved them to
//! a variable, and the solver reads no generation-time context (§6.2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Schemes = @import("Schemes.zig");
const Context = @import("Context.zig");
const Generalize = @import("Generalize.zig");
const Walk = @import("Walk.zig");
const lists = @import("../lists.zig");
const Evidence = @import("Evidence.zig");

const Instantiate = @This();

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

cx: *const Context,
frames: *std.ArrayList(Generalize.Frame),
stacks: *Walk.Stacks,
/// The generalised roots the copy in progress memoised, so their `copy`
/// slots are cleared afterwards without a second walk.
copied: std.ArrayList(Var) = .empty,
instantiations: u64 = 0,
/// The declaration being solved, for a too-deep note (§15.2): set by the
/// solver at each `member` node.
decl: ?u32 = null,
/// Where an instantiation's requirements become wanteds (§4.2): one per
/// requirement of the scheme, with the instruction that instantiated it as
/// their origin. Null in a unit test with no evidence tables.
evidence: ?*Evidence = null,
/// The module's creation counter, shared with obligations (§9.1).
seq: *u32 = undefined,
/// The current frame's queue (`Obligations.current_queue`), for a wanted's
/// `frame` (§9.1).
queue: *u32 = undefined,
/// The instruction the copy in progress is FOR (`copy`'s caller sets it).
origin: Bir.Inst.Index = @enumFromInt(0),
/// The wanted whose resolution asked for the copy in progress (an
/// instance's context, §9.3 step 4), or none: the lineage of §9.5.
parent: Evidence.WantedId.Optional = .none,
/// The wanteds the last `copy` or `reference` created, in the scheme's
/// canonical order.
made: std.ArrayList(Evidence.WantedId) = .empty,
/// Constraint entries the copy in progress made (`mappedConstraints`).
entries: u32 = 0,
/// Instantiations whose entries were not all paired with a wanted: the
/// solver reports each as `internal`.
unpaired: u32 = 0,
/// The interface term memo every imported scheme and constructor is read
/// through (`Schemes.TermMemo`).
term_memo: Schemes.TermMemo = .{},

pub fn deinit(in: *Instantiate) void {
    in.copied.deinit(in.cx.gpa);
    in.made.deinit(in.cx.gpa);
    in.term_memo.deinit(in.cx.gpa);
}

fn frame(in: *Instantiate) *Generalize.Frame {
    return &in.frames.items[in.frames.items.len - 1];
}

/// Pool every variable the store gained since `mark` at the frame's rank:
/// `Types.Builder` and `Schemes.instantiate` make variables themselves, and
/// the descriptor column is append-only, so what is new is a range.
pub fn adoptSince(in: *Instantiate, mark: u32) Error!void {
    const f = in.frame();
    const store = in.cx.store;
    var i = mark;
    while (i < store.count()) : (i += 1) {
        const v: Var = @enumFromInt(i);
        if (store.rank(v) == f.rank) try lists.push(Var, &f.pool, in.cx.gpa, v);
    }
}

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

/// A fresh instance of `v` in the current frame: every generalised node is
/// copied once, every other node is shared.
pub fn copy(in: *Instantiate, v: Var) Error!Var {
    const store = in.cx.store;
    const gpa = in.cx.gpa;
    in.instantiations += 1;
    const root = store.find(v);
    if (store.rank(root) != TypeStore.generalized) return root;

    const f = in.frame();
    const start = in.copied.items.len;
    // Pass 1: one fresh variable per generalised node, memoised.
    const stack = &in.stacks.vars;
    stack.clearRetainingCapacity();
    try stack.append(gpa, root);
    while (stack.pop()) |next| {
        const r = store.find(next);
        if (store.rank(r) != TypeStore.generalized) continue;
        if (store.copy(r) != .none) continue;
        const c = try store.fresh(.err, f.rank);
        try lists.push(Var, &f.pool, gpa, c);
        store.setCopy(r, c.toOptional());
        try lists.push(Var, &in.copied, gpa, r);
        var n: u32 = 0;
        while (Walk.owned(store, in.stacks.obligations, r, n)) |ch| : (n += 1) {
            const cr = store.find(ch);
            if (store.rank(cr) == TypeStore.generalized and store.copy(cr) == .none) try lists.push(Var, stack, gpa, cr);
        }
    }
    // Pass 2: each copy's content, its successors mapped through the memo.
    in.entries = 0;
    for (in.copied.items[start..]) |r| {
        const c = store.copy(r).unwrap().?;
        store.setContent(c, try in.mapped(r));
    }
    // The requirements it copied become wanteds, in canonical order,
    // read off the scheme while the memo still maps it to the copy.
    if (in.entries != 0) try in.wantInOrder(root, true);
    const result = store.copy(root).unwrap().?;
    for (in.copied.items[start..]) |r| store.setCopy(r, .none);
    in.copied.shrinkRetainingCapacity(start);
    return result;
}

// ---------------------------------------------------------------------------
// Templates (checker-v2.md §11.2)
// ---------------------------------------------------------------------------

/// A TEMPLATE of `v`: the whole type graph reachable from it, of any rank,
/// copied at rank `generalized`, with the root of each `from[i]` replaced by
/// `to[i]` and every other variable a fresh generalised flex with its name
/// and kind and nothing riding on it — no requirement, no obligation. What a
/// derived context keeps of a method type its fixpoint frame computed
/// (`Contexts`): the frame's variables are discarded, so a type that outlives
/// it is copied out, over the type's own template parameters (`to`), and
/// instantiated later with `substitute`. Iterative, like `copy`.
pub fn freeze(in: *Instantiate, v: Var, from: []const Var, to: []const Var) Error!Var {
    const store = in.cx.store;
    const gpa = in.cx.gpa;
    for (from, to) |f, t| store.setCopy(store.find(f), t.toOptional());
    defer for (from) |f| store.setCopy(store.find(f), .none);
    const start = in.copied.items.len;
    const stack = &in.stacks.vars;
    stack.clearRetainingCapacity();
    try stack.append(gpa, store.find(v));
    while (stack.pop()) |next| {
        const r = store.find(next);
        if (store.copy(r) != .none) continue;
        const c = try store.fresh(.err, TypeStore.generalized);
        store.setCopy(r, c.toOptional());
        try lists.push(Var, &in.copied, gpa, r);
        var n: u32 = 0;
        while (Walk.child(store, r, n, .structural)) |ch| : (n += 1) {
            if (store.copy(store.find(ch)) == .none) try stack.append(gpa, ch);
        }
    }
    for (in.copied.items[start..]) |r| {
        const c = store.copy(r).unwrap().?;
        store.setContent(c, switch (store.content(r)) {
            .flex, .rigid => |flags| .{ .flex = .{ .name = flags.name, .kind = flags.kind } },
            else => try in.mapped(r),
        });
    }
    const result = image(store, v);
    for (in.copied.items[start..]) |r| store.setCopy(r, .none);
    in.copied.shrinkRetainingCapacity(start);
    return result;
}

/// Template `t` instantiated in the current frame with each template
/// parameter `params[i]` replaced by `args[i]` (`freeze`'s inverse): the
/// ordinary `copy`, whose memo is seeded with the substitution.
pub fn substitute(in: *Instantiate, t: Var, params: []const Var, args: []const Var) Error!Var {
    const store = in.cx.store;
    for (params, args) |p, a| store.setCopy(store.find(p), store.find(a).toOptional());
    defer for (params) |p| store.setCopy(store.find(p), .none);
    return in.copy(t);
}

/// What a copied node's copy is: `n`'s own copy when it has one, else `n`
/// itself (shared).
fn image(store: *TypeStore, n: Var) Var {
    const r = store.find(n);
    return store.copy(r).unwrap() orelse r;
}

fn mappedRange(in: *Instantiate, range: TypeStore.Range) Error!TypeStore.Range {
    const store = in.cx.store;
    const source = try in.cx.scratch.dupe(Var, store.vars(range));
    defer in.cx.scratch.free(source);
    for (source) |*x| x.* = image(store, x.*);
    return store.addVars(source);
}

fn mappedConstraints(in: *Instantiate, flags: TypeStore.Flags) Error!TypeStore.ConstraintSet.Optional {
    const store = in.cx.store;
    const set = Walk.constraints(flags);
    const n = set.count(store);
    if (n == 0) return .none;
    const built = try in.cx.scratch.alloc(TypeStore.MethodConstraint, n);
    defer in.cx.scratch.free(built);
    for (built, 0..) |*c, i| {
        const original = set.at(store, @intCast(i));
        c.* = .{ .name = original.name, .fn_var = image(store, original.fn_var), .region = original.region, .origin = original.origin };
    }
    in.entries += n;
    return (try store.addConstraints(built)).toOptional();
}

/// One wanted per requirement, by construction: the requirements of
/// `scheme` become wanteds in
/// §12.1's canonical order (`Evidence.requirements`, the one function the
/// writer, promotion and P6 read), so an instantiation's evidence is in the
/// order its callee takes it and nothing downstream reorders it. For a copy
/// (`copied`) each requirement's receiver is its quantifier's copy; an
/// imported scheme's variables are its own. Every entry the copy made must be
/// paired: one that is not counts in `unpaired`, which the solver reports as
/// `internal` (§4.2).
fn wantInOrder(in: *Instantiate, scheme: Var, copied: bool) Error!void {
    if (in.evidence == null) return;
    const store = in.cx.store;
    const scratch = in.cx.scratch;
    var reqs: std.ArrayList(Evidence.Requirement) = .empty;
    defer reqs.deinit(scratch);
    try Evidence.requirements(store, in.cx.interner, scheme, scratch, &reqs);
    var made: u32 = 0;
    for (reqs.items) |r| {
        const receiver = if (copied)
            (if (store.rank(r.root) == TypeStore.generalized) (store.copy(r.root).unwrap() orelse continue) else continue)
        else
            r.root;
        const set = Walk.constraints(store.flagsOf(receiver));
        try in.want(receiver, set.at(store, r.index), Evidence.position(store, set.set, r.index));
        made += 1;
    }
    if (made != in.entries) in.unpaired += 1;
}

/// One requirement of the scheme being instantiated becomes a wanted:
/// its receiver is the copy of the quantifier, its method type the copy of
/// the requirement's, and it rides on the receiver at `position` — an open
/// entry of a fresh variable's set, until a unification readies it.
fn want(in: *Instantiate, receiver: Var, c: TypeStore.MethodConstraint, at: u32) Error!void {
    const evidence = in.evidence orelse return;
    const gpa = in.cx.gpa;
    const id = try evidence.add(gpa, .{
        .method = c.name,
        .receiver = receiver,
        .method_type = c.fn_var,
        .origin = in.origin,
        .kind = c.origin,
        .decl = in.decl orelse Evidence.Wanted.no_decl,
        .parent = in.parent,
        .seq = in.seq.*,
        .frame = in.queue.*,
        .receiver_name = in.cx.store.flagsOf(receiver).name,
    });
    in.seq.* += 1;
    try evidence.setSlot(gpa, at, .wanted(id));
    try in.made.append(gpa, id);
}

/// The requirements an imported scheme read onto the variables made since
/// `mark` become wanteds, as a copy's do (`want`). `Schemes.instantiate`
/// hands each constrained quantifier a fresh set of its own.
fn wantImported(in: *Instantiate, mark: u32, scheme: Var) Error!void {
    const store = in.cx.store;
    in.entries = 0;
    var i = mark;
    while (i < store.count()) : (i += 1) {
        in.entries += Walk.constraints(store.flagsOf(@enumFromInt(i))).count(store);
    }
    if (in.entries != 0) try in.wantInOrder(scheme, false);
}
/// A copied node's content. Instantiating an annotation's promise turns it
/// into an ordinary variable: inside the body `a` is rigid, at a use it is
/// whatever the use needs (Elm's `makeCopyHelp`).
fn mapped(in: *Instantiate, r: Var) Error!TypeStore.Content {
    const store = in.cx.store;
    return switch (store.content(r)) {
        .err => .err,
        .flex, .rigid => |flags| blk: {
            // The flags copied and changed field by field: the
            // constraints mapped through the memo, and no obligation — a
            // generalised variable carries none open (§8.1 step 7), and a
            // copy must not share a row with its scheme.
            var copied = flags;
            copied.constraints = try in.mappedConstraints(flags);
            copied.obls = .none;
            break :blk .{ .flex = copied };
        },
        .alias => |a| .{ .alias = .{ .type = a.type, .args = try in.mappedRange(a.args), .actual = image(store, a.actual) } },
        .structure => |flat| .{ .structure = switch (flat) {
            .unit, .empty_record => flat,
            .func => |fun| .{ .func = .{ .params = try in.mappedRange(fun.params), .result = image(store, fun.result) } },
            .app => |a| .{ .app = .{ .type = a.type, .args = try in.mappedRange(a.args) } },
            .tuple => |t| .{ .tuple = try in.mappedRange(t) },
            .record => |rec| blk: {
                const source = try in.cx.scratch.dupe(TypeStore.Field, store.fields(rec.fields));
                defer in.cx.scratch.free(source);
                for (source) |*fld| fld.value = image(store, fld.value);
                break :blk .{ .record = .{ .fields = try store.addFields(source), .ext = image(store, rec.ext) } };
            },
        } },
    };
}

// ---------------------------------------------------------------------------
// What a reference names
// ---------------------------------------------------------------------------

/// The type the reference at `region` names, not yet copied, or null for a
/// reference that cannot be typed (already reported, or a dependency that
/// failed): the caller poisons.
pub fn reference(in: *Instantiate, region: Bir.Inst.Index) Error!?Var {
    const cx = in.cx;
    in.origin = region;
    const bir = cx.bir;
    const data = bir.instData(region);
    return switch (bir.instTag(region)) {
        .ctor => try in.ownCtor(data.lhs, region),
        .ext_value => try in.imported(@enumFromInt(data.lhs), .value, data.rhs),
        .ext_ctor => try in.importedCtor(@enumFromInt(data.lhs), data.rhs),
        .ext_schema_member => try in.imported(@enumFromInt(data.lhs), .schema_member, data.rhs),
        .ext_schema_ctor => try in.imported(@enumFromInt(data.lhs), .schema_ctor, data.rhs),
        .schema_member_top => blk: {
            const kind = std.enums.fromInt(Interface.SchemaMember.Kind, data.rhs) orelse break :blk null;
            break :blk cx.schemas.member(data.lhs, kind);
        },
        .schema_ctor_top => blk: {
            const ref = Bir.SchemaCtorRef.unpack(data.rhs);
            break :blk try cx.schemas.constructor(@enumFromInt(data.lhs), if (ref.encoded) .encoded else .type, ref.variant);
        },
        else => null,
    };
}

/// Another module's value `index`, instantiated with its requirements as
/// wanteds of `origin` (a method the module rule found, §9.3 step 3).
pub fn importedValue(in: *Instantiate, module: Graph.Index, index: u32) Error!?Var {
    return in.imported(module, .value, index);
}

const Imported = enum { value, schema_member, schema_ctor };

/// A value, schema member or schema constructor of another module,
/// instantiated from its interface at the frame's rank.
fn imported(in: *Instantiate, module: Graph.Index, which: Imported, index: u32) Error!?Var {
    const cx = in.cx;
    if (module.int() >= cx.interfaces.len) return null;
    const iface = cx.iface(module);
    const scheme = switch (which) {
        .value => if (index < iface.values.len) iface.values[index].scheme else return null,
        .schema_member => if (index < iface.schema_members.len) iface.schema_members[index].scheme else return null,
        .schema_ctor => if (index < iface.schema_ctors.len) iface.schema_ctors[index].scheme else return null,
    };
    if (scheme == .none) return null;
    const mark = cx.store.count();
    const v = try Schemes.instantiateWith(iface, cx.types.refIds(module), cx.store, @intFromEnum(scheme), in.frame().rank, cx.scratch, &in.term_memo, cx.gpa);
    try in.adoptSince(mark);
    try in.wantImported(mark, v);
    return v;
}

/// A constructor of another module, from its interface's `arg_terms`.
fn importedCtor(in: *Instantiate, module: Graph.Index, index: u32) Error!?Var {
    const cx = in.cx;
    if (module.int() >= cx.interfaces.len) return null;
    const iface = cx.iface(module);
    if (index >= iface.ctors.len) return null;
    const type_id = cx.types.ofInterface(module, iface.ctors[index].type);
    if (type_id == .none) return null;
    const mark = cx.store.count();
    const v = try Schemes.instantiateCtorWith(iface, cx.types.refIds(module), cx.store, index, type_id, in.frame().rank, cx.scratch, &in.term_memo, cx.gpa) orelse return null;
    try in.adoptSince(mark);
    return v;
}

/// A constructor of THIS module, built fresh at the frame's rank — which is
/// its instantiation: nothing is shared with another use.
fn ownCtor(in: *Instantiate, index: u32, region: Bir.Inst.Index) Error!?Var {
    const cx = in.cx;
    const bir = cx.bir;
    if (index >= bir.ctors.len) return null;
    const c = bir.ctors[index];
    const owner = bir.decl(c.decl);
    const id = cx.types.ofDecl(cx.module, c.decl);
    if (id == .none) return null;
    const rank = in.frame().rank;

    const mark = cx.store.count();
    var b: Types.Builder = .init(cx.store, cx.types, cx.graph, cx.artifacts, cx.module, bir, .flex, rank, cx.scratch, cx.interner);
    defer b.deinit();
    const params = bir.declTypeParams(owner);
    const param_vars = try cx.scratch.alloc(Var, params.len);
    defer cx.scratch.free(param_vars);
    for (params, param_vars) |p, *v| {
        v.* = try cx.store.fresh(.{ .flex = .{ .name = p.toOptional() } }, rank);
        try b.bind(p, v.*);
    }
    const args = bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index);
    const arg_vars = try cx.scratch.alloc(Var, args.len);
    defer cx.scratch.free(arg_vars);
    for (args, arg_vars) |arg, *v| v.* = try b.read(arg);
    // The guard poisoned an argument: the type is a hole, and a message
    // goes with it.
    if (b.too_deep) try cx.noteTooDeep(region, in.decl);
    const result = try b.apply(id, param_vars);
    if (arg_vars.len == 0) {
        try in.adoptSince(mark);
        return result;
    }
    const range = try cx.store.addVars(arg_vars);
    const fun = try cx.store.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } }, rank);
    try in.adoptSince(mark);
    return fun;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const small_stack = @import("../small_stack.zig");

/// Twice the depth a copy that recursed once per level fails at on
/// `small_stack.size`: one finished 1 000 levels on the Debug test binary
/// and overflowed at 3 000.
const deep_type = 6_000;

test "copy keeps sharing, shares what is not generalised, and walks a type deeper than a recursive copy survives" {
    // The copy keeps its own stack (`Walk.Stacks`), so it runs on
    // `small_stack`'s few pages at any depth.
    try small_stack.run(copyKeepsSharing, .{});
}

fn copyKeepsSharing() !void {
    var store: TypeStore = .init(testing.allocator);
    defer store.deinit();
    var stacks: Walk.Stacks = .{};
    defer stacks.deinit(testing.allocator);
    var frames: std.ArrayList(Generalize.Frame) = .empty;
    defer {
        for (frames.items) |*f| f.deinit(testing.allocator);
        frames.deinit(testing.allocator);
    }
    try frames.append(testing.allocator, .{ .rank = 1 });
    var too_deep: std.ArrayList(Context.TooDeep) = .empty;
    const cx: Context = .{
        .gpa = testing.allocator,
        .scratch = testing.allocator,
        .store = &store,
        .types = undefined,
        .graph = undefined,
        .artifacts = undefined,
        .interner = undefined,
        .interfaces = &.{},
        .module = @enumFromInt(0),
        .bir = undefined,
        .schemas = undefined,
        .too_deep = &too_deep,
    };
    var in: Instantiate = .{ .cx = &cx, .frames = &frames, .stacks = &stacks };
    defer in.deinit();

    // ∀a. ( a, a, outer ), with `outer` a monomorphic variable.
    const a = try store.fresh(.{ .flex = .{} }, TypeStore.generalized);
    const outer = try store.freshFlex(1);
    const elems = try store.addVars(&.{ a, a, outer });
    const tuple = try store.fresh(.{ .structure = .{ .tuple = elems } }, TypeStore.generalized);
    const c = try in.copy(tuple);
    const copied = store.vars(store.content(c).structure.tuple);
    try testing.expect(copied[0] != a);
    try testing.expectEqual(copied[0], copied[1]);
    try testing.expectEqual(outer, copied[2]);
    try testing.expectEqual(@as(u32, 1), store.rank(copied[0]));

    var v = a;
    for (0..deep_type) |_| {
        const args = try store.addVars(&.{v});
        v = try store.fresh(.{ .structure = .{ .app = .{ .type = @enumFromInt(0), .args = args } } }, TypeStore.generalized);
    }
    const deep = try in.copy(v);
    try testing.expect(deep != v);
    try testing.expectEqual(@as(u32, 1), store.rank(deep));
}
