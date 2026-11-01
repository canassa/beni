//! L11: the transfer rules (`docs/design/ownership-v2.md` §2.6), one case per
//! BIR tag, over one declaration's instructions in evaluation order. A
//! value is a shape root with its own κ snapshot (§2.9); the frame records,
//! for `Walk` and `Demands`, the uses (at the consumer, R-4.1.1), the
//! demands, the holders (bindings and pending computed operands), the
//! escapes and what the calls rely on.
//!
//! **What S3a builds**: locals, field and tuple projections, literals,
//! lists, tuples, records and constructor applications as containers, the
//! spread chains `Lower` recorded (§2.13.2: a construction past the first
//! spread, a prepend before it), `++` chains (one demand on the leftmost
//! operand, R-2.2), `let`s, `case`s and their patterns (a list pattern
//! splits its container, §2.13.3), top-level values (`shared`, §2.13.11),
//! and calls of the classes the rows give (`Calls`). A call whose every
//! argument and result cross does nothing. **Anything else** — a lambda, a
//! local function, a record update, a call of a summarised declaration or
//! a function value, markup, `?`, a schema — is not built yet: the frame
//! says so (`unbuilt`) and the declaration gets the pessimistic class,
//! never a refusal (§8, S3a).
//!
//! **Points.** A use is at its consumer; a value bound by a `let` is bound
//! where its value is complete, a pattern where its root is matched, a
//! parameter at its pattern. A computed operand is pending from its own
//! point to its consumer's.
//!
//! **The frame is seven files (§5).** This one declares the frame's
//! fields, binds the six parts' methods into `Frame` by name, and holds
//! the preliminary passes and the walk (`eval`). Each part is `Of(Frame)`,
//! methods over the frame passed down, in the order their code depends:
//! `TransferFrame` (accessors, value helpers, uses), `TransferBeside` (a
//! write's other paths and what is beside it, §2.11 item 3),
//! `TransferPattern` (patterns and splits), `TransferConstruct`
//! (constructions), `TransferCall` (call application) and `TransferGroups`
//! (a use below a parameter's leaf, expanded after the walk). A part calls
//! only the parts before it; a caller sees one `Transfer.Frame`.
//!
//! Obligations kept here: O1 (a construct's node over-approximates what it
//! produces; an unknown is `⊤`), O2 (uses at consumers, at the path read,
//! with their kind), O6's pattern half (a list pattern's element and rest
//! are the two sides of one split), O7 (a construction's result is its
//! base's object written), O13 (a literal's and a construction's κ by
//! §2.9's rules); the code of O6's pattern half is `TransferPattern`'s,
//! of O7 and O13 `TransferConstruct`'s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Place = @import("Place.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Regions = @import("Regions.zig");
const Demands = @import("Demands.zig");
const Calls = @import("Calls.zig");
const Bir = @import("../bir/Bir.zig");
const TransferFrame = @import("TransferFrame.zig");
const TransferBeside = @import("TransferBeside.zig");
const TransferArms = @import("TransferArms.zig");
const TransferPattern = @import("TransferPattern.zig");
const TransferConstruct = @import("TransferConstruct.zig");
const TransferCall = @import("TransferCall.zig");
const TransferGroups = @import("TransferGroups.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const PlaceId = Ids.PlaceId;
pub const CondId = Ids.CondId;
pub const ClassId = Ids.ClassId;
pub const Value = Demands.Value;
pub const Env = Summary.Env;
pub const Step = Place.Step;
pub const Error = Ids.ChargeError;
pub const none: u32 = Ids.none_int;
const Inst = Bir.Inst;

const Val = TransferFrame.Val;
pub const Group = TransferGroups.Group;
pub const CallSnap = TransferGroups.CallSnap;
pub const Plain = TransferGroups.Plain;

const frame_part = TransferFrame.Of(Frame);
const beside_part = TransferBeside.Of(Frame);
const arms_part = TransferArms.Of(Frame);
const pattern_part = TransferPattern.Of(Frame);
const construct_part = TransferConstruct.Of(Frame);
const call_part = TransferCall.Of(Frame);
const group_part = TransferGroups.Of(Frame);

/// What a call runs, as the module adapter resolves it (L13).
pub const Callee = union(enum) {
    /// A class to apply, at this call's instantiation.
    class: ClassId,
    /// A constructor: its ordinal in its type.
    ctor: u32,
    /// Every argument and the result cross: nothing happens.
    harmless,
    /// Not built in this slice.
    unbuilt,
};

/// What the walk asks of the module (§5: upward needs go through an
/// interface passed down). Every answer is source input.
pub const Context = struct {
    ctx: *anyopaque,
    /// The place of an instruction's solved type.
    placeOfInst: *const fn (ctx: *anyopaque, inst: u32) Error!PlaceId,
    /// The place of a local's solved type (declaration-relative index).
    placeOfLocal: *const fn (ctx: *anyopaque, local: u32) Error!PlaceId,
    /// The text rank of a field name (a BIR symbol).
    fieldRank: *const fn (ctx: *anyopaque, symbol: Bir.SymbolIndex) u32,
    /// What a `call` or `method_call` runs.
    callee: *const fn (ctx: *anyopaque, inst: u32) Error!Callee,
    /// A constructor reference's ordinal in its type, and its arity.
    ctorOf: *const fn (ctx: *anyopaque, ref: u32) ?[2]u32,
    /// A reference to a parameterless top-level value: its `shared` index;
    /// null for a function.
    sharedIndex: *const fn (ctx: *anyopaque, ref: u32) ?u32,
    /// A `++` the checker resolved to `List.append` (`Dispatch`).
    isListAppend: *const fn (ctx: *anyopaque, inst: u32) bool,
    /// Told of every call a class answered, with its arguments: a
    /// recursive group records its edges (§8 S3b slice 4b).
    onCall: ?*const fn (ctx: *anyopaque, inst: u32, args: []const Value) Error!void = null,
};

/// A parameter cell a consumed value holds (`Frame.readsOf`): read at its
/// path (`use_node` none), or there with a callee's use below it.
pub const ParamRead = struct { cell: CellId, use_node: NodeId };

pub const Frame = struct {
    gpa: Allocator,
    env: Env,
    sums: *const Summary.Table,
    ctx: Context,
    bir: *const Bir,
    decl: Bir.Decl,
    regions: *const Regions.Tree,
    /// The declaration's parameter places (its signature's), when known: a
    /// pattern parameter has no type of its own.
    param_places: []const PlaceId = &.{},
    vals: []Val = &.{},
    locals: []Value = &.{},
    bound: []bool = &.{},
    /// Per instruction: who consumes its value, and at which point.
    consumer: []u32 = &.{},
    point_of: []u32 = &.{},
    /// Per instruction: lowered internals of a spread or `++` chain.
    absorbed: []bool = &.{},
    /// Per instruction: the `Bir.Spread` it roots, or `none`.
    chain: []u32 = &.{},
    /// Per instruction: a pattern root and the instruction whose value it
    /// matches (a case's scrutinee), or a `let` pattern's value and the
    /// pattern it binds.
    matches: []u32 = &.{},
    binds: []u32 = &.{},
    uses: std.ArrayList(Facts.Use) = .empty,
    /// Per use: its consumer's main token, the position a message prints.
    use_tokens: std.ArrayList(u32) = .empty,
    /// The parameter parts consumed values hold, for the read-off's `R`
    /// (`readsOf`): no liveness use, which is a local's (§2.7).
    param_reads: std.ArrayList(ParamRead) = .empty,
    demands: std.ArrayList(Demands.Demand) = .empty,
    operands: std.ArrayList(Demands.Operand) = .empty,
    holders: std.ArrayList(Demands.Holder) = .empty,
    escapes: std.ArrayList(Demands.Escape) = .empty,
    /// Per local: its binding holder, or `none`.
    binding: []u32 = &.{},
    /// What the calls of this frame rely on (their `xreq`, instantiated).
    xreq: CondId = Cond.yes,
    /// The first instruction not built yet, or `none`.
    unbuilt: u32 = none,
    calls: Calls.Scratch = .{},
    scratch: std.ArrayList(Inst.Index) = .empty,
    /// The write routes that stopped at a parameter's leaf, and the calls
    /// they are of (§2.11 item 3, #1412): expanded after the walk.
    groups: std.ArrayList(Group) = .empty,
    /// `otherPaths`' certified views while it runs (§2.11 item 3 (d), #1485):
    /// a `TransferBeside.Cert`.
    cert: ?*anyopaque = null,
    group_steps: std.ArrayList(Step) = .empty,
    call_snaps: std.ArrayList(CallSnap) = .empty,
    call_args: std.ArrayList(Inst.Index) = .empty,

    pub fn deinit(f: *Frame) void {
        const gpa = f.gpa;
        gpa.free(f.vals);
        gpa.free(f.locals);
        gpa.free(f.bound);
        gpa.free(f.consumer);
        gpa.free(f.point_of);
        gpa.free(f.absorbed);
        gpa.free(f.chain);
        gpa.free(f.matches);
        gpa.free(f.binds);
        gpa.free(f.binding);
        f.uses.deinit(gpa);
        f.use_tokens.deinit(gpa);
        f.param_reads.deinit(gpa);
        f.demands.deinit(gpa);
        f.operands.deinit(gpa);
        f.holders.deinit(gpa);
        f.escapes.deinit(gpa);
        f.calls.deinit(gpa);
        f.scratch.deinit(gpa);
        f.groups.deinit(gpa);
        f.group_steps.deinit(gpa);
        f.call_snaps.deinit(gpa);
        f.call_args.deinit(gpa);
    }

    // ---- the parts' methods, bound by name (§5) -------------------------------

    // TransferFrame.zig
    pub const rel = frame_part.rel;
    pub const account = frame_part.account;
    pub const tag = frame_part.tag;
    pub const data = frame_part.data;
    pub const token = frame_part.token;
    pub const val = frame_part.val;
    pub const lane = frame_part.lane;
    pub const sized = frame_part.sized;
    pub const markUnbuilt = frame_part.markUnbuilt;
    pub const args = frame_part.args;
    pub const placeOf = frame_part.placeOf;
    pub const set1 = frame_part.set1;
    pub const nothing = frame_part.nothing;
    pub const topValue = frame_part.topValue;
    pub const opaqueOf = frame_part.opaqueOf;
    pub const kappaSet = frame_part.kappaSet;
    pub const kappaSetElem = frame_part.kappaSetElem;
    pub const consume = frame_part.consume;
    pub const readsOf = frame_part.readsOf;
    pub const paramReads = frame_part.paramReads;
    pub const pending = frame_part.pending;
    pub const bindLocal = frame_part.bindLocal;
    pub const reentries = frame_part.reentries;
    // TransferBeside.zig
    pub const extendPath = beside_part.extendPath;
    pub const otherPaths = beside_part.otherPaths;
    pub const advancePush = beside_part.advancePush;
    pub const wantOf = beside_part.wantOf;
    pub const advance = beside_part.advance;
    pub const routePath = beside_part.routePath;
    pub const frontierAt = beside_part.frontierAt;
    pub const routesBelow = beside_part.routesBelow;
    pub const reachBeside = beside_part.reachBeside;
    pub const ownContents = beside_part.ownContents;
    pub const without = beside_part.without;
    pub const spineOf = beside_part.spineOf;
    pub const pushOff = beside_part.pushOff;
    pub const holdsCanonical = beside_part.holdsCanonical;
    pub const pathBelow = beside_part.pathBelow;
    pub const keepAnswered = beside_part.keepAnswered;
    pub const keepBeside = beside_part.keepBeside;
    pub const keepReach = beside_part.keepReach;
    pub const spineRefinements = beside_part.spineRefinements;
    pub const otherSide = beside_part.otherSide;
    pub const atWritten = beside_part.atWritten;
    pub const splitBeside = beside_part.splitBeside;
    pub const unreached = beside_part.unreached;
    pub const leafDepth = beside_part.leafDepth;
    pub const positionsAt = beside_part.positionsAt;
    pub const summaryPath = beside_part.summaryPath;
    pub const along = beside_part.along;
    pub const certStep = beside_part.certStep;
    pub const certKid = beside_part.certKid;
    pub const certKidsAll = beside_part.certKidsAll;
    pub const certKidsOff = beside_part.certKidsOff;
    pub const certDetect = beside_part.certDetect;
    pub const certCells = beside_part.certCells;
    pub const certReach = beside_part.certReach;
    pub const BesideItem = beside_part.Item;
    pub const BesidePush = beside_part.Push;
    pub const BesideWritten = beside_part.Written;
    pub const BesideWant = beside_part.Want;
    // TransferArms.zig
    pub const Arms = arms_part.Arms;
    pub const Synthetic = arms_part.Synthetic;
    pub const MPos = arms_part.MPos;
    pub const synthetic = arms_part.synthetic;
    pub const expandOne = arms_part.expandOne;
    pub const frontierMax = arms_part.frontierMax;
    pub const routesMax = arms_part.routesMax;
    pub const readStep = arms_part.readStep;
    // TransferPattern.zig
    pub const bind = pattern_part.bind;
    pub const below = pattern_part.below;
    pub const project = pattern_part.project;
    pub const projectAt = pattern_part.projectAt;
    pub const splitTargets = pattern_part.splitTargets;
    pub const bindList = pattern_part.bindList;
    // TransferConstruct.zig
    pub const literal = construct_part.literal;
    pub const fit = construct_part.fit;
    pub const container = construct_part.container;
    pub const construct = construct_part.construct;
    pub const demand = construct_part.demand;
    pub const spreadChain = construct_part.spreadChain;
    pub const prepend = construct_part.prepend;
    pub const appendChain = construct_part.appendChain;
    // TransferCall.zig
    pub const call = call_part.call;
    // TransferGroups.zig
    pub const expandGroups = group_part.expandGroups;
    pub const namedPaths = group_part.namedPaths;
    pub const aliveAtGroup = group_part.aliveAtGroup;
    pub const linkHolder = group_part.linkHolder;
    pub const addNamed = group_part.addNamed;
    pub const paramCell = group_part.paramCell;
    pub const snapArgs = group_part.snapArgs;
    pub const addExtra = group_part.addExtra;
    pub const groupTrie = group_part.groupTrie;
    pub const holdersOn = group_part.holdersOn;
    pub const holderOn = group_part.holderOn;
    pub const expandGroup = group_part.expandGroup;
    pub const groupDemand = group_part.groupDemand;

    // ---- the preliminary passes ------------------------------------------------

    /// Consumers, chains and pattern roots: one pass over the instructions.
    fn prepare(f: *Frame) Error!void {
        const gpa = f.gpa;
        const n = f.decl.inst_end.int() - f.decl.inst_start.int();
        f.vals = try gpa.alloc(Val, n);
        @memset(f.vals, .{});
        f.consumer = try gpa.alloc(u32, n);
        @memset(f.consumer, none);
        f.point_of = try gpa.alloc(u32, n);
        f.absorbed = try gpa.alloc(bool, n);
        @memset(f.absorbed, false);
        f.chain = try gpa.alloc(u32, n);
        @memset(f.chain, none);
        f.matches = try gpa.alloc(u32, n);
        @memset(f.matches, none);
        f.binds = try gpa.alloc(u32, n);
        @memset(f.binds, none);
        const nl = f.decl.locals_end - f.decl.locals_start;
        f.locals = try gpa.alloc(Value, nl);
        @memset(f.locals, .{});
        f.bound = try gpa.alloc(bool, nl);
        @memset(f.bound, false);
        f.binding = try gpa.alloc(u32, nl);
        @memset(f.binding, none);
        var i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            f.scratch.clearRetainingCapacity();
            try f.bir.operands(gpa, @fromBackingInt(i), &f.scratch);
            for (f.scratch.items) |o| {
                if (o.int() < f.decl.inst_start.int() or o.int() >= f.decl.inst_end.int()) continue;
                f.consumer[f.rel(o.int())] = i;
            }
            switch (f.tag(i)) {
                .branch => {
                    // The arm's pattern matches the case's scrutinee: the
                    // case is the branch's consumer, found below.
                },
                .let_pattern => f.binds[f.rel(f.data(i).rhs)] = f.data(i).lhs,
                else => {},
            }
        }
        // A branch's pattern matches its case's scrutinee.
        i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            if (f.tag(i) != .case) continue;
            const scrutinee = f.data(i).lhs;
            for (f.bir.extraSlice(f.bir.subRange(@fromBackingInt(f.data(i).rhs)), Inst.Index)) |b| {
                f.matches[f.rel(f.data(b.int()).lhs)] = scrutinee;
            }
        }
        // Points: a value bound by a `let`, a scrutinee: its own point.
        for (f.point_of, 0..) |*p, r| {
            const c = f.consumer[r];
            const self: u32 = @intCast(r + f.decl.inst_start.int());
            p.* = if (c == none) self else switch (f.tag(c)) {
                .let_def, .let_pattern => self,
                .case => if (f.data(c).lhs == self) self else c,
                else => c,
            };
        }
        // Spread chains: their roots, and the lowered calls inside them.
        for (f.bir.spreads(f.decl), 0..) |s, si| {
            if (s.root < f.decl.inst_start.int() or s.root >= f.decl.inst_end.int()) continue;
            f.chain[f.rel(s.root)] = @intCast(si);
            var items: std.ArrayList(u32) = .empty;
            defer items.deinit(gpa);
            for (f.bir.spreadItems(s)) |it| try items.append(gpa, it[0]);
            try f.absorb(s.root, items.items);
        }
        // `++` chains: an inner `++` on lists is its outer one's.
        i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            if (f.tag(i) != .call or !f.ctx.isListAppend(f.ctx.ctx, i)) continue;
            const a = f.args(i);
            if (a.len != 2) continue;
            const inner = a[1].int();
            if (f.tag(inner) == .call and f.ctx.isListAppend(f.ctx.ctx, inner) and f.args(inner).len == 2) {
                f.absorbed[f.rel(inner)] = true;
                f.absorbed[f.rel(f.data(inner).lhs)] = true;
            }
        }
    }

    /// The lowered calls (and a trailing literal) between a chain's root
    /// and its items.
    fn absorb(f: *Frame, root: u32, items: []const u32) Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(f.gpa);
        try stack.append(f.gpa, root);
        while (stack.pop()) |c| {
            if (std.mem.indexOfScalar(u32, items, c) != null) continue;
            if (c != root) f.absorbed[f.rel(c)] = true;
            switch (f.tag(c)) {
                .call => {
                    f.absorbed[f.rel(f.data(c).lhs)] = true;
                    for (f.args(c)) |a| try stack.append(f.gpa, a.int());
                },
                .list => for (f.bir.extraSlice(Bir.inlineRange(f.data(c)), Inst.Index)) |e| try stack.append(f.gpa, e.int()),
                else => {},
            }
        }
    }

    // ---- the walk ----------------------------------------------------------------

    /// One instruction's value (§2.6's table).
    fn eval(f: *Frame, i: u32) Error!Val {
        const d = f.data(i);
        const t = f.tag(i);
        if (f.absorbed[f.rel(i)]) return .{};
        if (t.isType() or t.isPattern()) return .{};
        if (f.chain[f.rel(i)] != none) {
            const s = f.bir.spreads(f.decl)[f.chain[f.rel(i)]];
            return .{ .value = try f.spreadChain(i, s) };
        }
        switch (t) {
            .local => {
                if (!f.bound[d.lhs]) {
                    f.markUnbuilt(i);
                    return .{ .value = try f.topValue(try f.placeOf(i)) };
                }
                const at = try f.ctx.placeOfLocal(f.ctx.ctx, d.lhs);
                return .{ .value = f.locals[d.lhs], .local = d.lhs, .path = try f.env.places.rootPath(f.gpa, at) };
            },
            .field_access, .tuple_index => {
                const target = f.val(d.lhs);
                const step = if (t == .field_access) try Step.field(f.account(), f.ctx.fieldRank(f.ctx.ctx, @fromBackingInt(d.rhs))) else try Step.index(f.account(), d.rhs);
                const v = try f.project(target.value, step, i);
                if (target.local != none) {
                    if (try f.env.places.extend(f.gpa, f.env.charge, target.path, step)) |p| return .{ .value = v, .local = target.local, .path = p };
                    try f.consume(d.lhs, i, .whole, .none);
                }
                return .{ .value = v };
            },
            .top, .ext_value => {
                if (f.isCallee(i)) return .{};
                const idx = f.ctx.sharedIndex(f.ctx.ctx, i) orelse {
                    f.markUnbuilt(i);
                    return .{ .value = try f.topValue(try f.placeOf(i)) };
                };
                const at = try f.placeOf(i);
                const root = try f.env.places.rootPath(f.gpa, at);
                const c = try f.env.cells.symbolic(f.gpa, f.account(), f.env.places, .shared, idx, root, 0);
                return .{ .value = .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, try f.set1(c)) } };
            },
            .ctor, .ext_ctor => {
                if (f.isCallee(i)) return .{};
                const ord = f.ctx.ctorOf(f.ctx.ctx, i) orelse {
                    f.markUnbuilt(i);
                    return .{};
                };
                if (ord[1] != 0) {
                    f.markUnbuilt(i);
                    return .{};
                }
                return .{ .value = try f.container(i, &.{}, &.{}, false) };
            },
            .int, .float, .char, .string, .chunk, .unit => return .{ .value = try f.nothing(try f.placeOf(i)) },
            .interp => {
                for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |p| try f.consume(p.int(), i, .whole, .none);
                return .{ .value = try f.nothing(try f.placeOf(i)) };
            },
            .@"error" => return .{ .value = try f.topValue(try f.placeOf(i)) },
            .list => {
                var items: std.ArrayList(u32) = .empty;
                defer items.deinit(f.gpa);
                for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index)) |e| {
                    try f.consume(e.int(), i, .whole, .none);
                    try items.append(f.gpa, e.int());
                }
                return .{ .value = try f.literal(i, items.items) };
            },
            .tuple => {
                var parts: std.ArrayList(u32) = .empty;
                defer parts.deinit(f.gpa);
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(f.gpa);
                for (f.bir.extraSlice(Bir.inlineRange(d), Inst.Index), 0..) |e, k| {
                    try f.consume(e.int(), i, .whole, .none);
                    try parts.append(f.gpa, e.int());
                    try steps.append(f.gpa, try Step.index(f.account(), @intCast(k)));
                }
                return .{ .value = try f.container(i, parts.items, steps.items, false) };
            },
            .record => {
                var parts: std.ArrayList(u32) = .empty;
                defer parts.deinit(f.gpa);
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(f.gpa);
                for (f.bir.extraSlice(Bir.inlineRange(d), Bir.Field)) |fld| {
                    try f.consume(fld.value.int(), i, .whole, .none);
                    try parts.append(f.gpa, fld.value.int());
                    try steps.append(f.gpa, try Step.field(f.account(), f.ctx.fieldRank(f.ctx.ctx, fld.name)));
                }
                return .{ .value = try f.container(i, parts.items, steps.items, true) };
            },
            .call => {
                if (f.ctx.isListAppend(f.ctx.ctx, i) and f.args(i).len == 2) return .{ .value = try f.appendChain(i) };
                return .{ .value = try f.call(i, d.lhs, f.args(i)) };
            },
            .method_call => {
                const m = f.bir.extraData(@fromBackingInt(d.rhs), Bir.MethodCall);
                var all: std.ArrayList(Inst.Index) = .empty;
                defer all.deinit(f.gpa);
                try all.append(f.gpa, @fromBackingInt(d.lhs));
                try all.appendSlice(f.gpa, f.bir.extraSlice(.{ .start = m.args_start, .end = m.args_end }, Inst.Index));
                return .{ .value = try f.call(i, i, all.items) };
            },
            .let => return f.val(d.rhs),
            .let_def => {
                const def = f.bir.extraData(@fromBackingInt(d.lhs), Bir.LetDef);
                if (def.params_end != def.params_start) f.markUnbuilt(i);
                return .{};
            },
            .let_pattern => return .{},
            .let_stmt => {
                try f.consume(d.rhs, i, .whole, .none);
                return .{};
            },
            // A branch's value is read where the arm ends (§2.7: the join's
            // uses): the value it evaluates to is used there, in its arm.
            .branch => {
                try f.consume(d.rhs, i, .whole, .none);
                return f.val(d.rhs);
            },
            .case => {
                const branches = f.bir.extraSlice(f.bir.subRange(@fromBackingInt(d.rhs)), Inst.Index);
                var members: std.ArrayList(NodeId) = .empty;
                defer members.deinit(f.gpa);
                var ctxs: std.ArrayList(Cond.Kappas) = .empty;
                defer ctxs.deinit(f.gpa);
                const at = try f.placeOf(i);
                for (branches) |b| {
                    const v = try f.fit(f.val(b.int()).value, at);
                    try members.append(f.gpa, v.node);
                    try ctxs.append(f.gpa, v.kappa);
                }
                if (members.items.len == 0) return .{ .value = try f.nothing(at) };
                // The join walks the arms' values whole: a general task, named
                // growth until it is charged by position (#1098).
                const task = try f.account().enter(f.gpa, null);
                defer f.account().leave(task);
                const copy = try f.gpa.dupe(NodeId, members.items);
                defer f.gpa.free(copy);
                // One arm runs: its arms are exclusive alternatives (§2.3).
                const joined = try f.env.shapes.joinAlternatives(f.gpa, f.account(), f.env.places, f.env.cells, copy);
                var kappa: Cond.Kappas = .none;
                for (ctxs.items) |k| kappa = try f.env.conds.kappaMerge(f.gpa, f.env.charge, kappa, k);
                kappa = try f.env.conds.propagate(f.gpa, f.env.charge, f.env.view(), kappa, joined, members.items, ctxs.items, .alternatives, false, null);
                return .{ .value = .{ .node = joined, .kappa = kappa } };
            },
            else => {
                // lambda, record_update, try, markup, type_dispatch, schemas.
                f.markUnbuilt(i);
                return .{ .value = try f.topValue(try f.placeOf(i)) };
            },
        }
    }

    fn isCallee(f: *const Frame, i: u32) bool {
        const c = f.consumer[f.rel(i)];
        return c != none and (f.tag(c) == .call or f.tag(c) == .pat_ctor) and f.data(c).lhs == i;
    }

    /// Walk every instruction in order: bind the parameters, evaluate, bind
    /// `let` values and match patterns where they complete, mark computed
    /// operands pending, record the body's value as a whole use (a return).
    pub fn walk(f: *Frame) Error!void {
        try f.prepare();
        const params = f.bir.extraSlice(.{ .start = f.decl.params_start, .end = f.decl.params_end }, Inst.Index);
        for (params, 0..) |p, k| {
            const kernel = try f.account().enter(f.gpa, .{ .atom = p.int(), .role = .direct_data });
            defer f.account().leave(kernel);
            // A pattern has no type of its own; a variable has its local's.
            const at = if (k < f.param_places.len) f.param_places[k] else if (f.tag(p.int()) == .pat_var) try f.ctx.placeOfLocal(f.ctx.ctx, f.data(p.int()).lhs) else try f.placeOf(p.int());
            const root = try f.env.places.rootPath(f.gpa, at);
            const c = try f.env.cells.symbolic(f.gpa, f.account(), f.env.places, .param, @intCast(k), root, 0);
            const kids = f.env.places.kind(at);
            const v: Value = if (kids == .cross) try f.nothing(at) else .{ .node = try f.env.shapes.leaf(f.gpa, f.account(), at, try f.set1(c)) };
            try f.bind(p.int(), v, p.int());
        }
        var i = f.decl.inst_start.int();
        while (i < f.decl.inst_end.int()) : (i += 1) {
            if (f.unbuilt != none) return;
            // §4.1: an instruction's transfer is its own settlement kernel.
            const kernel = try f.account().enter(f.gpa, .{ .atom = i, .role = .transfer_settlement });
            defer f.account().leave(kernel);
            const r = f.rel(i);
            const t = f.tag(i);
            if (f.matches[r] != none) {
                // A case arm's pattern root: match the scrutinee here.
                try f.bind(i, f.val(f.matches[r]).value, i);
                continue;
            }
            f.vals[r] = try f.eval(i);
            if (t.isType() or t.isPattern()) continue;
            // A `let` value completes its binding; a `let` pattern its match.
            const c = f.consumer[r];
            if (c != none and f.tag(c) == .let_def and f.data(c).rhs == i) {
                const def = f.bir.extraData(@fromBackingInt(f.data(c).lhs), Bir.LetDef);
                try f.consume(i, c, .whole, .none);
                try f.bindLocal(def.local, f.vals[r].value, i);
                continue;
            }
            if (f.binds[r] != none) {
                try f.consume(i, c, .whole, .none);
                try f.bind(f.binds[r], f.vals[r].value, i);
                continue;
            }
            if (c != none and f.tag(c) == .case and f.data(c).lhs == i) {
                try f.consume(i, c, .whole, .none);
                continue;
            }
            try f.pending(i);
        }
        if (f.decl.body.unwrap()) |body| try f.consume(body.int(), body.int(), .whole, .none);
    }

    /// The value of the body: what the declaration returns.
    pub fn result(f: *const Frame) Value {
        const body = f.decl.body.unwrap() orelse return .{};
        return f.val(body.int()).value;
    }
};
