//! L4: regions and points (`docs/design/ownership-v2.md` §2.5). A point is
//! an instruction index. The region tree is read off the BIR once per
//! declaration: a region per `case` arm, `let` body and frame body (a
//! lambda, a local function), with its range, parent, case and arm, and
//! for an arm its guard when the scrutinee is `i == e`. The
//! `withDefault (map m f) d` shapes the pre-pass found are two virtual arms
//! of one virtual case (§2.13.12).
//!
//! Instructions of a declaration are contiguous and every operand precedes
//! its consumer, so a subtree is the range `[first(e), e]`; regions are
//! laminar and the innermost region of every point is found by one sweep.
//!
//! **Compatible** (§2.5): two points are compatible when neither lies in an
//! arm of a case the other lies in a different arm of — the climb to their
//! regions' lowest common ancestor, O(depth). **After `p`, compatible** is
//! at most `depth` ranges (`rangesAfter`).
//!
//! Obligations kept here: O2's region half (a use is recorded in the right
//! region: `of` is the innermost region of the point).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Prepass = @import("Prepass.zig");
const Bir = @import("../bir/Bir.zig");
const stamped = @import("../stamped.zig");

pub const RegionId = Ids.RegionId;
pub const none: u32 = Ids.none_int;

pub const Kind = enum(u8) {
    /// The declaration's own body: the root.
    body,
    /// A `case` arm: `case_inst` and `arm` say which.
    arm,
    /// A `let`'s body.
    let_body,
    /// A frame boundary: a lambda's or a local function's body.
    frame,
    /// An arm of a virtual `case` for `withDefault (map m f) d`.
    virtual_arm,
};

pub const Region = struct {
    kind: Kind,
    /// The instructions `[start, end]`, inclusive.
    start: u32,
    end: u32,
    parent: RegionId,
    depth: u32,
    /// `arm`, `virtual_arm`: the `case` (or outer call) instruction.
    case_inst: u32,
    /// `arm`, `virtual_arm`: the arm's index.
    arm: u32,
    /// `arm`: the `i == e` scrutinee (a `method_call` of `eq`) when the
    /// case is on one, else `none`. Whether `Dispatch` resolves it to
    /// `Int`'s is the reader's question (§2.13.15).
    guard: u32,
};

pub const Tree = struct {
    regions: std.MultiArrayList(Region) = .empty,
    /// Per instruction of the declaration (relative to `inst_start`): its
    /// innermost region.
    of: []RegionId = &.{},
    inst_start: u32 = 0,

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        t.regions.deinit(gpa);
        gpa.free(t.of);
    }

    pub fn get(t: *const Tree, r: RegionId) Region {
        return t.regions.get(r.int());
    }

    pub fn count(t: *const Tree) u32 {
        return @intCast(t.regions.len);
    }

    /// The innermost region of point `p`.
    pub fn regionOf(t: *const Tree, p: u32) RegionId {
        return t.of[p - t.inst_start];
    }

    /// Whether points `a` and `b` are compatible (§2.5).
    pub fn compatible(t: *const Tree, a: u32, b: u32) bool {
        return t.compatibleRegions(t.regionOf(a), t.regionOf(b));
    }

    pub fn compatibleRegions(t: *const Tree, ra: RegionId, rb: RegionId) bool {
        const depths = t.regions.items(.depth);
        const parents = t.regions.items(.parent);
        var x = ra;
        var y = rb;
        var below_x: RegionId = .none;
        var below_y: RegionId = .none;
        while (depths[x.int()] > depths[y.int()]) {
            below_x = x;
            x = parents[x.int()];
        }
        while (depths[y.int()] > depths[x.int()]) {
            below_y = y;
            y = parents[y.int()];
        }
        while (x != y) {
            below_x = x;
            below_y = y;
            x = parents[x.int()];
            y = parents[y.int()];
        }
        if (below_x == .none or below_y == .none) return true;
        const kx = t.regions.items(.kind)[below_x.int()];
        const ky = t.regions.items(.kind)[below_y.int()];
        if (!(kx == .arm or kx == .virtual_arm) or !(ky == .arm or ky == .virtual_arm)) return true;
        const cases = t.regions.items(.case_inst);
        const arms = t.regions.items(.arm);
        return !(cases[below_x.int()] == cases[below_y.int()] and arms[below_x.int()] != arms[below_y.int()]);
    }

    /// The `i == e` guard of the arm `p` lies in, or `none`.
    pub fn guard(t: *const Tree, p: u32) u32 {
        var r = t.regionOf(p);
        while (r != .none) : (r = t.regions.items(.parent)[r.int()]) {
            if (t.regions.items(.kind)[r.int()] == .arm) return t.regions.items(.guard)[r.int()];
        }
        return none;
    }

    pub const Range = struct { start: u32, end: u32 };

    /// The instruction ranges after `p` that are compatible with it, at
    /// most `depth` of them, in ascending order: the rest of `p`'s region,
    /// then of each ancestor past the sibling arms of the child on the
    /// chain (an arm's siblings end with their `case` instruction).
    pub fn rangesAfter(t: *const Tree, gpa: Allocator, p: u32, out: *std.ArrayList(Range)) Allocator.Error!void {
        out.clearRetainingCapacity();
        var r = t.regionOf(p);
        var from = p + 1;
        var skips: std.ArrayList(Range) = .empty;
        defer skips.deinit(gpa);
        while (r != .none) {
            const reg = t.get(r);
            // The other arms of this region's case that lie ahead are
            // incompatible and cut out of the parent's range: for a `case`
            // they fill the gap up to the case instruction, for a virtual
            // case (`withDefault (map m f) d`) the inner call sits between.
            if (from <= reg.end) try t.appendMinus(gpa, from, reg.end, skips.items, out);
            skips.clearRetainingCapacity();
            if (reg.kind == .arm or reg.kind == .virtual_arm) try t.siblingArms(gpa, r, reg, &skips);
            from = reg.end + 1;
            r = reg.parent;
        }
    }

    /// `[from, end]` with `skips` (sorted, disjoint) cut out, appended.
    fn appendMinus(t: *const Tree, gpa: Allocator, from: u32, end: u32, skips: []const Range, out: *std.ArrayList(Range)) Allocator.Error!void {
        _ = t;
        var at = from;
        for (skips) |s| {
            if (s.end < at) continue;
            if (s.start > end) break;
            if (s.start > at) try out.append(gpa, .{ .start = at, .end = s.start - 1 });
            at = s.end + 1;
        }
        if (at <= end) try out.append(gpa, .{ .start = at, .end = end });
    }

    /// The other arms of `arm`'s case, sorted by start. Arms of one case
    /// are created consecutively, so they are the neighbouring ids with the
    /// same case instruction.
    fn siblingArms(t: *const Tree, gpa: Allocator, arm: RegionId, reg: Region, out: *std.ArrayList(Range)) Allocator.Error!void {
        const cases = t.regions.items(.case_inst);
        const starts = t.regions.items(.start);
        const ends = t.regions.items(.end);
        var lo = arm.int();
        while (lo > 0 and cases[lo - 1] == reg.case_inst) lo -= 1;
        var hi = arm.int();
        while (hi + 1 < t.regions.len and cases[hi + 1] == reg.case_inst) hi += 1;
        var i = lo;
        while (i <= hi) : (i += 1) {
            if (i == arm.int()) continue;
            try out.append(gpa, .{ .start = starts[i], .end = ends[i] });
        }
        std.mem.sort(Range, out.items, {}, struct {
            fn lessThan(_: void, a: Range, b: Range) bool {
                return a.start < b.start;
            }
        }.lessThan);
    }

    /// Whether point `q` lies in `[p + 1, ∞)` compatibly with `p`.
    pub fn afterCompatible(t: *const Tree, p: u32, q: u32) bool {
        return q > p and t.compatible(p, q);
    }
};

/// Build the tree of declaration `d`, which must have a body. `prepass`
/// supplies the virtual arms (`joins`); O(instructions of `d`).
pub fn build(gpa: Allocator, bir: *const Bir, d: Bir.Decl, prepass: ?*const Facts.Prepass) Allocator.Error!Tree {
    var t: Tree = .{ .inst_start = d.inst_start.int() };
    errdefer t.deinit(gpa);
    const n = d.inst_end.int() - d.inst_start.int();
    const body = d.body.unwrap() orelse {
        t.of = try gpa.alloc(RegionId, n);
        @memset(t.of, .none);
        return t;
    };
    // `first[i]`: the first instruction of `i`'s subtree.
    const first = try gpa.alloc(u32, n);
    defer gpa.free(first);
    for (first, 0..) |*f, i| f.* = @intCast(d.inst_start.int() + i);
    try Prepass.subtreeStarts(gpa, bir, d, first);
    try t.regions.append(gpa, .{ .kind = .body, .start = d.inst_start.int(), .end = d.inst_end.int() - 1, .parent = .none, .depth = 0, .case_inst = none, .arm = 0, .guard = none });
    // Walk the body, opening a region per arm, let body and frame; the
    // parent is the innermost open region, found by the stack.
    const Frame = struct { inst: Bir.Inst.Index, region: RegionId };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var ops: std.ArrayList(Bir.Inst.Index) = .empty;
    defer ops.deinit(gpa);
    // Instructions a virtual case pins to one of its arms (§2.13.12).
    var pinned: stamped.Column(u32, RegionId) = .{};
    defer pinned.deinit(gpa);
    try stack.append(gpa, .{ .inst = body, .region = .from(0) });
    for (bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index)) |p| try stack.append(gpa, .{ .inst = p, .region = .from(0) });
    while (stack.pop()) |f| {
        const tag = bir.instTag(f.inst);
        const data = bir.instData(f.inst);
        var region = f.region;
        switch (tag) {
            .case => {
                const scrutinee: Bir.Inst.Index = @fromBackingInt(@intCast(data.lhs));
                const g: u32 = if (bir.instTag(scrutinee) == .method_call and bir.extraData(@fromBackingInt(@intCast(bir.instData(scrutinee).rhs)), Bir.MethodCall).origin == .eq) scrutinee.int() else none;
                try stack.append(gpa, .{ .inst = scrutinee, .region = region });
                for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index), 0..) |arm, k| {
                    const r = try open(&t, gpa, .arm, first[arm.int() - t.inst_start], arm.int(), region, f.inst.int(), @intCast(k), g);
                    try stack.append(gpa, .{ .inst = arm, .region = r });
                }
                continue;
            },
            .let => {
                const b: Bir.Inst.Index = @fromBackingInt(@intCast(data.rhs));
                const r = try open(&t, gpa, .let_body, first[b.int() - t.inst_start], b.int(), region, none, 0, none);
                try stack.append(gpa, .{ .inst = b, .region = r });
                for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.lhs))), Bir.Inst.Index)) |def| try stack.append(gpa, .{ .inst = def, .region = region });
                continue;
            },
            .lambda => {
                region = try open(&t, gpa, .frame, first[f.inst.int() - t.inst_start], f.inst.int() - 1, region, none, 0, none);
            },
            .let_def => {
                const def = bir.extraData(@fromBackingInt(@intCast(data.lhs)), Bir.LetDef);
                if (def.params_end != def.params_start) {
                    const b: Bir.Inst.Index = @fromBackingInt(@intCast(data.rhs));
                    const start = @min(first[b.int() - t.inst_start], first[bir.extraSlice(.{ .start = def.params_start, .end = def.params_end }, Bir.Inst.Index)[0].int() - t.inst_start]);
                    region = try open(&t, gpa, .frame, start, b.int(), region, none, 0, none);
                }
            },
            .call => if (prepass) |pp| {
                for (pp.joins) |j| {
                    if (j.outer != f.inst.int()) continue;
                    // `case m of Just x → f x; Nothing → d`: `f` and `d` are
                    // pinned to arms of their own, wherever under the outer
                    // call the walk reaches them (`f` through the inner call).
                    try pinned.put(gpa, j.f, try open(&t, gpa, .virtual_arm, first[j.f - t.inst_start], j.f, region, j.outer, 0, none));
                    try pinned.put(gpa, j.d, try open(&t, gpa, .virtual_arm, first[j.d - t.inst_start], j.d, region, j.outer, 1, none));
                }
            },
            else => {},
        }
        ops.clearRetainingCapacity();
        try bir.operands(gpa, f.inst, &ops);
        for (ops.items) |o| try stack.append(gpa, .{ .inst = o, .region = pinned.get(o.int()) orelse region });
    }
    // The innermost region of every instruction: a sweep over the laminar
    // ranges, regions sorted by (start, -end).
    const order = try gpa.alloc(u32, t.regions.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const starts = t.regions.items(.start);
    const ends = t.regions.items(.end);
    const SortCtx = struct {
        s: []const u32,
        e: []const u32,
        fn lessThan(c: @This(), a: u32, b: u32) bool {
            return if (c.s[a] != c.s[b]) c.s[a] < c.s[b] else c.e[a] > c.e[b];
        }
    };
    std.mem.sort(u32, order, SortCtx{ .s = starts, .e = ends }, SortCtx.lessThan);
    t.of = try gpa.alloc(RegionId, n);
    var open_regions: std.ArrayList(u32) = .empty;
    defer open_regions.deinit(gpa);
    var next: usize = 0;
    var i: u32 = d.inst_start.int();
    while (i < d.inst_end.int()) : (i += 1) {
        while (open_regions.items.len > 0 and ends[open_regions.items[open_regions.items.len - 1]] < i) _ = open_regions.pop();
        while (next < order.len and starts[order[next]] <= i) : (next += 1) {
            if (ends[order[next]] >= i) try open_regions.append(gpa, order[next]);
        }
        t.of[i - t.inst_start] = if (open_regions.items.len > 0) .from(open_regions.items[open_regions.items.len - 1]) else .from(0);
    }
    return t;
}

fn open(t: *Tree, gpa: Allocator, k: Kind, start: u32, end: u32, parent: RegionId, case_inst: u32, arm: u32, g: u32) Allocator.Error!RegionId {
    const id: RegionId = .from(@intCast(t.regions.len));
    try t.regions.append(gpa, .{ .kind = k, .start = start, .end = end, .parent = parent, .depth = t.regions.items(.depth)[parent.int()] + 1, .case_inst = case_inst, .arm = arm, .guard = g });
    return id;
}

comptime {
    Ids.assertRecord(Region);
    std.debug.assert(@sizeOf(Region) == 32);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const module_text =
    \\module Main exposing (g)
    \\
    \\g : Int, List Int → Int
    \\g n xs =
    \\    let
    \\        h k =
    \\            case xs of
    \\                [ x, …_ ] →
    \\                    x + k
    \\
    \\                [] →
    \\                    k
    \\    in
    \\    if n == 0 then h 1 else (λy → y) 2
;

/// The `branch` instructions of declaration `d`, in order.
fn branches(bir: *const Bir, d: Bir.Decl, out: *std.ArrayList(u32)) !void {
    var i = d.inst_start.int();
    while (i < d.inst_end.int()) : (i += 1) if (bir.instTag(@fromBackingInt(i)) == .branch) try out.append(testing.allocator, i);
}

test "arms of one case are incompatible, everything else compatible; guards and ranges" {
    var l = try Prepass.lowerSource(module_text);
    defer l.deinit();
    const d = l.bir.decls[l.declNamed("g")];
    var t = try build(testing.allocator, &l.bir, d, null);
    defer t.deinit(testing.allocator);
    var arms: std.ArrayList(u32) = .empty;
    defer arms.deinit(testing.allocator);
    try branches(&l.bir, d, &arms);
    // Four branches: the inner case's two, then the `if`'s two.
    try testing.expectEqual(@as(usize, 4), arms.items.len);
    // A point in each arm: the branch's body.
    const body = struct {
        fn of(bir: *const Bir, branch: u32) u32 {
            return bir.instData(@fromBackingInt(branch)).rhs;
        }
    }.of;
    const a0 = body(&l.bir, arms.items[0]);
    const a1 = body(&l.bir, arms.items[1]);
    const if0 = body(&l.bir, arms.items[2]);
    const if1 = body(&l.bir, arms.items[3]);
    try testing.expect(!t.compatible(a0, a1));
    try testing.expect(!t.compatible(if0, if1));
    try testing.expect(t.compatible(a0, if0));
    try testing.expect(t.compatible(a1, if1));
    try testing.expect(t.compatible(a0, a0));
    // Regions: body, the let body, h's frame, two arms, two if arms, the lambda frame.
    try testing.expectEqual(@as(u32, 8), t.count());
    const ra0 = t.get(t.regionOf(a0));
    try testing.expectEqual(Kind.arm, ra0.kind);
    try testing.expectEqual(@as(u32, 0), ra0.arm);
    try testing.expectEqual(Kind.frame, t.get(ra0.parent).kind);
    // The inner case is on `xs`: no guard; the `if` is on `n == 0`: a guard.
    try testing.expectEqual(none, t.guard(a0));
    try testing.expect(t.guard(if0) != none);
    try testing.expectEqual(Bir.Inst.Tag.method_call, l.bir.instTag(@fromBackingInt(t.guard(if0))));
    // The lambda's body is a frame of its own, inside the second `if` arm.
    const lambda = l.firstTagged(l.declNamed("g"), .lambda);
    const lambda_body = l.bir.instData(@fromBackingInt(lambda)).rhs;
    const rl = t.get(t.regionOf(lambda_body));
    try testing.expectEqual(Kind.frame, rl.kind);
    try testing.expectEqual(t.regionOf(if1), rl.parent);
    try testing.expectEqual(lambda - 1, rl.end);
    // After a point in arm 0: the rest of the arm, then past the case —
    // never arm 1's instructions.
    var ranges: std.ArrayList(Tree.Range) = .empty;
    defer ranges.deinit(testing.allocator);
    try t.rangesAfter(testing.allocator, a0, &ranges);
    try testing.expect(ranges.items.len >= 2 and ranges.items.len <= 4);
    try testing.expectEqual(a0 + 1, ranges.items[0].start);
    var last: u32 = 0;
    for (ranges.items) |r| {
        try testing.expect(r.start > last);
        try testing.expect(r.start <= r.end);
        try testing.expect(!(r.start <= a1 and a1 <= r.end));
        last = r.end;
    }
    try testing.expect(t.afterCompatible(a0, if0) and !t.afterCompatible(a0, a1) and !t.afterCompatible(if0, a0));
    // Every instruction has a region, the parameters the body's.
    for (t.of) |r| try testing.expect(r != .none);
    try testing.expectEqual(@as(u32, 0), t.regionOf(d.inst_start.int()).int());
}

test "withDefault (map m f) d is two virtual arms of one case" {
    var l = try Prepass.lowerSource(
        \\module Main exposing (j)
        \\
        \\j mm dd =
        \\    Maybe.withDefault (Maybe.map mm (λx → x)) dd
    );
    defer l.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const targets = [_]Prepass.JoinTargets{.{
        .with_default = l.qualifiedTarget("Maybe", "withDefault"),
        .map = l.qualifiedTarget("Maybe", "map"),
    }};
    const pp = try Prepass.run(testing.allocator, arena_state.allocator(), .{ .bir = &l.bir, .joins = &targets });
    try testing.expectEqual(@as(usize, 1), pp.joins.len);
    const d = l.bir.decls[l.declNamed("j")];
    var t = try build(testing.allocator, &l.bir, d, &pp);
    defer t.deinit(testing.allocator);
    const j = pp.joins[0];
    // `f`'s body (the lambda's) is in the first virtual arm; `d` in the second.
    const f_body = l.bir.instData(@fromBackingInt(j.f)).rhs;
    try testing.expect(!t.compatible(f_body, j.d));
    try testing.expectEqual(Kind.virtual_arm, t.get(t.regionOf(j.d)).kind);
    // The lambda frame sits inside the virtual arm.
    const rf = t.get(t.regionOf(f_body));
    try testing.expectEqual(Kind.frame, rf.kind);
    try testing.expectEqual(Kind.virtual_arm, t.get(rf.parent).kind);
    // `m` and the outer call are in neither arm.
    try testing.expect(t.compatible(j.m, j.d) and t.compatible(j.m, f_body) and t.compatible(j.outer, j.d));
}

test "rangesAfter agrees with compatible around a virtual case" {
    var l = try Prepass.lowerSource(
        \\module Main exposing (j)
        \\
        \\j mm dd =
        \\    Maybe.withDefault (Maybe.map mm (λx → x)) dd
    );
    defer l.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const targets = [_]Prepass.JoinTargets{.{
        .with_default = l.qualifiedTarget("Maybe", "withDefault"),
        .map = l.qualifiedTarget("Maybe", "map"),
    }};
    const pp = try Prepass.run(testing.allocator, arena_state.allocator(), .{ .bir = &l.bir, .joins = &targets });
    const d = l.bir.decls[l.declNamed("j")];
    var t = try build(testing.allocator, &l.bir, d, &pp);
    defer t.deinit(testing.allocator);
    const j = pp.joins[0];
    const f_body = l.bir.instData(@fromBackingInt(j.f)).rhs;
    var ranges: std.ArrayList(Tree.Range) = .empty;
    defer ranges.deinit(testing.allocator);
    try t.rangesAfter(testing.allocator, f_body, &ranges);
    // Every instruction after `f`'s body is in the ranges exactly when it
    // is compatible: the inner call is, `d` is not, the outer call is.
    var q = f_body + 1;
    while (q < d.inst_end.int()) : (q += 1) {
        var covered = false;
        for (ranges.items) |r| if (r.start <= q and q <= r.end) {
            covered = true;
        };
        try testing.expectEqual(t.afterCompatible(f_body, q), covered);
    }
    var inner_covered = false;
    for (ranges.items) |r| if (r.start <= j.inner and j.inner <= r.end) {
        inner_covered = true;
    };
    try testing.expect(inner_covered);
}
