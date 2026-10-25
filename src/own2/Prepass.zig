//! L3: the BIR pre-pass (`docs/design/ownership-v2.md` §2.12, *The BIR
//! pre-pass*): one read of a module's BIR and dispatch table before any
//! frame is walked. It answers `Facts.Prepass`: the recursive groups
//! (`refs` ∪ the callees `Dispatch` resolves for a `method_call` ∪ the
//! declarations a derived `eq`/`compare` applies), alias chains of function
//! values (R-5.5.6), read counts of private parameterless values (R-4.9.3),
//! the enclosing frame of every lambda (§2.10), which declarations are a
//! type's `eq`/`compare` (§2.13.13), the spread chains `Lower` recorded
//! (§2.13.2) and the `withDefault (map m f) d` shapes (§2.13.12).
//!
//! **No name is compared to text here.** The `withDefault`/`map` targets
//! arrive resolved in `Input.joins` — the caller (L10) resolves them once
//! through the interner and the interfaces, which is §5's one allowlisted
//! name comparison — and are matched by instruction tag and payload. A
//! type's method is told by its symbol against the interner's fixed
//! `WellKnown` indices, never by spelling.
//!
//! **The spread table does not exist yet** (`Bir.Spread`, S2b): `spreads`
//! is published empty until `Lower` records it.
//!
//! Source-proportional: every pass is one walk over the declaration's
//! instructions, O(E) (§4.1's first row).
//!
//! Obligations kept here: none (facts about the text, no abstract value).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Scc = @import("../check/Scc.zig");
const InternPool = @import("../InternPool.zig");

pub const none: u32 = Ids.none_int;

/// A resolved callee the pre-pass matches an instruction against: the
/// instruction's tag and payload, exactly.
pub const Target = struct {
    tag: Bir.Inst.Tag,
    lhs: u32,
    rhs: u32,

    pub fn matches(t: Target, bir: *const Bir, inst: Bir.Inst.Index) bool {
        if (bir.instTag(inst) != t.tag) return false;
        const d = bir.instData(inst);
        return d.lhs == t.lhs and d.rhs == t.rhs;
    }
};

/// The two-call shapes of §2.13.12, resolved by the caller: `withDefault`
/// and `map` of one module, `Maybe`'s and `Result`'s.
pub const JoinTargets = struct {
    with_default: Target,
    map: Target,
};

pub const Input = struct {
    bir: *const Bir,
    /// The module's dispatch table, or null before the checker ran (a test).
    dispatch: ?*const Dispatch = null,
    joins: []const JoinTargets = &.{},
};

/// Run the pre-pass; the answer's slices are allocated in `arena`.
pub fn run(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error!Facts.Prepass {
    const bir = in.bir;
    const n = bir.decls.len;
    // ---- SCC edges ----
    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(gpa);
    const starts = try gpa.alloc(u32, n + 1);
    defer gpa.free(starts);
    const self_edge = try gpa.alloc(bool, n);
    defer gpa.free(self_edge);
    @memset(self_edge, false);
    const enclosing_frame = try arena.alloc(u32, bir.insts.len);
    @memset(enclosing_frame, none);
    const read_count = try arena.alloc(u32, n);
    @memset(read_count, 0);
    const reader = try arena.alloc(u32, n);
    @memset(reader, none);
    var joins: std.ArrayList(Facts.Prepass.MaybeJoin) = .empty;
    defer joins.deinit(gpa);
    var ops: std.ArrayList(Bir.Inst.Index) = .empty;
    defer ops.deinit(gpa);
    const tags = bir.insts.items(.tag);
    const datas = bir.insts.items(.data);
    for (bir.decls, 0..) |d, di| {
        starts[di] = @intCast(edges.items.len);
        if (!d.kind.isValue() or d.body == .none) continue;
        try frames(gpa, bir, d, enclosing_frame, &ops);
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) {
            const inst: Bir.Inst.Index = @fromBackingInt(i);
            switch (tags[i]) {
                .top => {
                    const target = datas[i].lhs;
                    if (target < n) {
                        if (target == di) self_edge[di] = true;
                        try edges.append(gpa, target);
                        // R-4.9.3: a direct read outside lambdas, by a
                        // parameterless initializer.
                        if (enclosing_frame[i] == none and d.params == 0) {
                            read_count[target] += 1;
                            reader[target] = if (read_count[target] == 1) @intCast(di) else none;
                        } else {
                            read_count[target] += 1;
                            reader[target] = none;
                        }
                    }
                },
                .method_call, .type_dispatch => if (in.dispatch) |dt| {
                    if (dt.siteOf(inst)) |site| {
                        if (site.callee.unwrap()) |ci| try termDecls(gpa, dt, ci, di, self_edge, &edges);
                        for (dt.argsAt(site.evidence)) |ti| try termDecls(gpa, dt, ti, di, self_edge, &edges);
                    }
                },
                .call => try join(gpa, bir, in.joins, inst, &joins),
                else => {},
            }
        }
    }
    starts[n] = @intCast(edges.items.len);
    const g = try Scc.sccGroups(arena, n, edges.items, starts);
    const group_count = g.starts.len - 1;
    const group_of = try arena.alloc(u32, n);
    const recursive = try arena.alloc(bool, group_count);
    for (0..group_count) |gi| {
        const members = g.order[g.starts[gi]..g.starts[gi + 1]];
        recursive[gi] = members.len > 1 or self_edge[members[0]];
        for (members) |m| group_of[m] = @intCast(gi);
    }
    // ---- alias chains, methods ----
    const alias_of = try arena.alloc(u32, n);
    const method_of = try arena.alloc(Facts.Prepass.MethodRole, n);
    for (bir.decls, 0..) |d, di| {
        alias_of[di] = none;
        method_of[di] = .{};
        if (!d.kind.isValue()) continue;
        if (d.params == 0) if (d.body.unwrap()) |b| {
            if (bir.instTag(b) == .top and bir.instData(b).lhs < n and bir.instData(b).lhs != di) alias_of[di] = bir.instData(b).lhs;
        };
        if (d.is_pub and d.kind == .value) {
            if (d.annotation.unwrap()) |a| if (bir.instTag(a) == .type_fn) {
                const name = bir.symbol(d.name);
                if (name == InternPool.WellKnown.eq.symbol()) method_of[di].eq = true;
                if (name == InternPool.WellKnown.compare.symbol()) method_of[di].compare = true;
            };
        }
    }
    // Follow alias chains to their end, a cycle stopping where it began.
    for (alias_of, 0..) |*a, di| {
        var at = a.*;
        var hops: usize = 0;
        while (at != none and alias_of[at] != none and hops < n) : (hops += 1) {
            if (alias_of[at] == di) break;
            at = alias_of[at];
        }
        a.* = at;
    }
    return .{
        .group_of = group_of,
        .order = g.order,
        .starts = g.starts,
        .recursive = recursive,
        .alias_of = alias_of,
        .read_count = read_count,
        .reader = reader,
        .method_of = method_of,
        .enclosing_frame = enclosing_frame,
        .spreads = &.{},
        .joins = try arena.dupe(Facts.Prepass.MaybeJoin, joins.items),
    };
}

/// Every `top` declaration an evidence term reaches (a derived
/// `eq`/`compare` applies the declared ones of its parts), as SCC edges.
fn termDecls(gpa: Allocator, dt: *const Dispatch, ti: Dispatch.TermIndex, di: usize, self_edge: []bool, edges: *std.ArrayList(u32)) Allocator.Error!void {
    const term = dt.term(ti);
    switch (term) {
        .top => |t| {
            if (t.decl.int() == di) self_edge[di] = true;
            try edges.append(gpa, t.decl.int());
        },
        else => {},
    }
    // Terms are allocated in pre-order, acyclic: the recursion is bounded by
    // the tree's depth.
    for (dt.argsOfTerm(ti)) |arg| try termDecls(gpa, dt, arg, di, self_edge, edges);
}

/// The enclosing frame of every lambda and local function of `d`
/// (§2.10's dynamic dependency edges): a walk with the frame on the stack.
fn frames(gpa: Allocator, bir: *const Bir, d: Bir.Decl, out: []u32, ops: *std.ArrayList(Bir.Inst.Index)) Allocator.Error!void {
    const Frame = struct { inst: Bir.Inst.Index, frame: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .inst = d.body.unwrap().?, .frame = none });
    while (stack.pop()) |f| {
        var frame = f.frame;
        switch (bir.instTag(f.inst)) {
            .lambda => {
                out[f.inst.int()] = frame;
                frame = f.inst.int();
            },
            .let_def => {
                const def = bir.extraData(@fromBackingInt(@intCast(bir.instData(f.inst).lhs)), Bir.LetDef);
                if (def.params_end != def.params_start) {
                    out[f.inst.int()] = frame;
                    frame = f.inst.int();
                } else {
                    // A constant's body belongs to the enclosing frame; its
                    // instructions are marked with it for R-4.9.3.
                    out[f.inst.int()] = frame;
                }
            },
            else => out[f.inst.int()] = frame,
        }
        ops.clearRetainingCapacity();
        try bir.operands(gpa, f.inst, ops);
        for (ops.items) |o| try stack.append(gpa, .{ .inst = o, .frame = frame });
    }
}

/// `first[i]` ← the first instruction of `i`'s subtree, for every
/// instruction of `d` (relative to `d.inst_start`): one post-order walk.
pub fn subtreeStarts(gpa: Allocator, bir: *const Bir, d: Bir.Decl, first: []u32) Allocator.Error!void {
    const Frame = struct { inst: Bir.Inst.Index, expanded: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var ops: std.ArrayList(Bir.Inst.Index) = .empty;
    defer ops.deinit(gpa);
    if (d.body.unwrap()) |b| try stack.append(gpa, .{ .inst = b, .expanded = false });
    for (bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index)) |p| try stack.append(gpa, .{ .inst = p, .expanded = false });
    while (stack.items.len > 0) {
        const f = &stack.items[stack.items.len - 1];
        if (f.expanded) {
            // Children are done: fold their starts in.
            const i = f.inst;
            _ = stack.pop();
            ops.clearRetainingCapacity();
            try bir.operands(gpa, i, &ops);
            var min = i.int();
            for (ops.items) |o| min = @min(min, first[o.int() - d.inst_start.int()]);
            first[i.int() - d.inst_start.int()] = min;
            continue;
        }
        f.expanded = true;
        const i = f.inst;
        ops.clearRetainingCapacity();
        try bir.operands(gpa, i, &ops);
        for (ops.items) |o| try stack.append(gpa, .{ .inst = o, .expanded = false });
    }
}

/// Whether `inst` is a variable path: a local, or field accesses and tuple
/// indices over one.
fn isVariablePath(bir: *const Bir, inst: Bir.Inst.Index) bool {
    var at = inst;
    while (true) switch (bir.instTag(at)) {
        .local => return true,
        .field_access, .tuple_index => at = @fromBackingInt(@intCast(bir.instData(at).lhs)),
        else => return false,
    };
}

/// §2.13.12: `withDefault (map m f) d`, both calls resolved to one
/// module's targets, `m` and `d` variable paths, `f` a lambda, a top-level
/// value or an imported one (a partial application is a lambda).
fn join(gpa: Allocator, bir: *const Bir, targets: []const JoinTargets, inst: Bir.Inst.Index, out: *std.ArrayList(Facts.Prepass.MaybeJoin)) Allocator.Error!void {
    const data = bir.instData(inst);
    const callee: Bir.Inst.Index = @fromBackingInt(@intCast(data.lhs));
    const args = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index);
    if (args.len != 2) return;
    for (targets) |t| {
        if (!t.with_default.matches(bir, callee)) continue;
        if (!isVariablePath(bir, args[1])) return;
        const inner = args[0];
        if (bir.instTag(inner) != .call) return;
        const idata = bir.instData(inner);
        if (!t.map.matches(bir, @fromBackingInt(@intCast(idata.lhs)))) return;
        const iargs = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(idata.rhs))), Bir.Inst.Index);
        if (iargs.len != 2 or !isVariablePath(bir, iargs[0])) return;
        switch (bir.instTag(iargs[1])) {
            .lambda, .top, .ext_value => {},
            else => return,
        }
        try out.append(gpa, .{ .outer = inst.int(), .inner = inner.int(), .m = iargs[0].int(), .f = iargs[1].int(), .d = args[1].int() });
        return;
    }
}

// ---------------------------------------------------------------------------
// Tests: source lowered in-process, no checker (`dispatch` null).
// ---------------------------------------------------------------------------

const testing = std.testing;
const Tokenizer = @import("../lex/Tokenizer.zig");
const Parse = @import("../parse/Parse.zig");
const Ast = @import("../parse/Ast.zig");
const Lower = @import("../bir/Lower.zig");

pub const Lowered = struct {
    interner: InternPool.Local,
    out: Tokenizer.Output,
    tree: Ast,
    bir: Bir,

    pub fn deinit(l: *Lowered) void {
        l.bir.deinit(testing.allocator);
        l.tree.deinit(testing.allocator);
        l.out.deinit(testing.allocator);
        l.interner.deinit(testing.allocator);
    }

    /// The declaration named `name`.
    pub fn declNamed(l: *const Lowered, name: []const u8) u32 {
        const sym = l.interner.find(name).?;
        for (l.bir.decls, 0..) |d, i| if (d.name != .none and l.bir.symbol(d.name) == sym) return @intCast(i);
        unreachable;
    }

    /// The `SymbolIndex` of `name` in this file's table.
    pub fn symbolIndex(l: *const Lowered, name: []const u8) u32 {
        const sym = l.interner.find(name).?;
        for (l.bir.symbols, 0..) |s, i| if (s == sym) return @intCast(i);
        unreachable;
    }

    /// The exact `qualified` reference `Module.name` as this file wrote it.
    pub fn qualifiedTarget(l: *const Lowered, module: []const u8, name: []const u8) Target {
        const m = l.interner.find(module).?;
        const s = l.interner.find(name).?;
        var i: u32 = 0;
        while (i < l.bir.insts.len) : (i += 1) {
            const inst: Bir.Inst.Index = @fromBackingInt(i);
            if (l.bir.instTag(inst) != .qualified) continue;
            const d = l.bir.instData(inst);
            if (l.bir.symbol(@fromBackingInt(@intCast(d.lhs))) == m and l.bir.symbol(@fromBackingInt(@intCast(d.rhs))) == s) return .{ .tag = .qualified, .lhs = d.lhs, .rhs = d.rhs };
        }
        unreachable;
    }

    /// The first instruction of `tag` in declaration `d`.
    pub fn firstTagged(l: *const Lowered, d: u32, tag: Bir.Inst.Tag) u32 {
        const decl = l.bir.decls[d];
        var i = decl.inst_start.int();
        while (i < decl.inst_end.int()) : (i += 1) if (l.bir.instTag(@fromBackingInt(i)) == tag) return i;
        unreachable;
    }
};

/// Lower `source` as a module `Main` of an application package.
pub fn lowerSource(source: [:0]const u8) !Lowered {
    const gpa = testing.allocator;
    var interner = try InternPool.Local.init(gpa);
    errdefer interner.deinit(gpa);
    var out: Tokenizer.Output = .empty;
    errdefer out.deinit(gpa);
    try Tokenizer.tokenize(gpa, source, &interner, &out);
    var tree = try Parse.parse(gpa, gpa, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    errdefer tree.deinit(gpa);
    const bir = try Lower.lower(gpa, gpa, source, out.tokens.slice(), &tree, &interner, .{ .core = false, .module_name = "Main" });
    return .{ .interner = interner, .out = out, .tree = tree, .bir = bir };
}

const module_text =
    \\module Main exposing (f)
    \\
    \\f : Int → Int
    \\f n =
    \\    if n > 0 then g (n - 1) else 0
    \\
    \\g : Int → Int
    \\g n =
    \\    f n
    \\
    \\h =
    \\    g
    \\
    \\k =
    \\    h
    \\
    \\v =
    \\    [ 1, 2 ]
    \\
    \\w =
    \\    List.length v
    \\
    \\v2 =
    \\    [ 3 ]
    \\
    \\u x =
    \\    (λy → v2) x
    \\
    \\pub eq : Int, Int → Bool
    \\eq a b =
    \\    True
    \\
    \\j mm dd =
    \\    Maybe.withDefault (Maybe.map mm (λx → x)) dd
    \\
    \\notj mm dd =
    \\    Maybe.withDefault (Maybe.andThen mm (λx → Just x)) dd
;

test "the pre-pass finds groups, alias chains, read counts, frames, methods and withDefault shapes" {
    var l = try lowerSource(module_text);
    defer l.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const targets = [_]JoinTargets{.{
        .with_default = l.qualifiedTarget("Maybe", "withDefault"),
        .map = l.qualifiedTarget("Maybe", "map"),
    }};
    const pp = try run(testing.allocator, arena_state.allocator(), .{ .bir = &l.bir, .joins = &targets });
    const f = l.declNamed("f");
    const g = l.declNamed("g");
    const h = l.declNamed("h");
    const k = l.declNamed("k");
    const v = l.declNamed("v");
    const w = l.declNamed("w");
    const v2 = l.declNamed("v2");
    const u = l.declNamed("u");
    // `f` and `g` are one recursive group; `h` is not in it.
    try testing.expectEqual(pp.group_of[f], pp.group_of[g]);
    try testing.expect(pp.recursive[pp.group_of[f]]);
    try testing.expect(pp.group_of[h] != pp.group_of[f]);
    try testing.expect(!pp.recursive[pp.group_of[h]]);
    // Dependencies first: `g`'s group comes before `h`'s.
    try testing.expect(pp.group_of[f] < pp.group_of[h]);
    // Alias chains end at `g`.
    try testing.expectEqual(g, pp.alias_of[h]);
    try testing.expectEqual(g, pp.alias_of[k]);
    try testing.expectEqual(none, pp.alias_of[f]);
    // `v` is read once, directly, by `w`; `v2` only inside a lambda.
    try testing.expectEqual(@as(u32, 1), pp.read_count[v]);
    try testing.expectEqual(w, pp.reader[v]);
    try testing.expectEqual(@as(u32, 1), pp.read_count[v2]);
    try testing.expectEqual(none, pp.reader[v2]);
    // The lambda in `u` is in the declaration's own frame; its body is in it.
    const lambda = l.firstTagged(u, .lambda);
    try testing.expectEqual(none, pp.enclosing_frame[lambda]);
    try testing.expectEqual(lambda, pp.enclosing_frame[l.bir.instData(@fromBackingInt(lambda)).rhs]);
    // `pub eq` with a function annotation is a type's `eq`.
    try testing.expect(pp.method_of[l.declNamed("eq")].eq and !pp.method_of[f].eq);
    // One join shape: `j`'s, not `notj`'s.
    try testing.expectEqual(@as(usize, 1), pp.joins.len);
    const jd = l.bir.decls[l.declNamed("j")];
    try testing.expect(pp.joins[0].outer >= jd.inst_start.int() and pp.joins[0].outer < jd.inst_end.int());
    try testing.expectEqual(Bir.Inst.Tag.lambda, l.bir.instTag(@fromBackingInt(pp.joins[0].f)));
    try testing.expectEqual(Bir.Inst.Tag.local, l.bir.instTag(@fromBackingInt(pp.joins[0].d)));
    try testing.expectEqual(@as(usize, 0), pp.spreads.len);
}

test "subtree starts: a post-ordered tree's first instruction" {
    var l = try lowerSource(module_text);
    defer l.deinit();
    const d = l.bir.decls[l.declNamed("f")];
    const first = try testing.allocator.alloc(u32, d.inst_end.int() - d.inst_start.int());
    defer testing.allocator.free(first);
    for (first, 0..) |*x, i| x.* = @intCast(d.inst_start.int() + i);
    try subtreeStarts(testing.allocator, &l.bir, d, first);
    // The body's subtree begins after the annotation and the parameter.
    const body = d.body.unwrap().?;
    const param = l.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index)[0];
    try testing.expectEqual(param.int() + 1, first[body.int() - d.inst_start.int()]);
    // A leaf is its own start.
    try testing.expectEqual(param.int(), first[param.int() - d.inst_start.int()]);
}
