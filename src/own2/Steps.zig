//! L2: one step of a position (`docs/design/ownership-v2.md` §2.3.2) and
//! the one relation of two different steps of one parent: `Frame.related`
//! answers a pair of positions by it, and every index that files positions
//! under their parent by step (`Entries.Within`, `Sweep.Live`,
//! `Stack.Index`) answers by the step classes it lists, so the pairs and
//! the indices cannot disagree (#1963).
//!
//! Obligations kept here: §2.3.2's step rule.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");

const PathId = Ids.PathId;
const Step = Place.Step;
const none: u32 = Ids.none_int;

/// A list step or a plain one (§2.3.2).
pub const PKind = enum(u8) { plain, front, back, slice };

pub const Pos = struct {
    root: u32,
    parent: u32,
    kind: PKind,
    /// `plain`: the step's word; `front`/`back`: the index; `slice`: from the front.
    a: u32,
    /// `slice`: from the back.
    b: u32,
    slot: PathId,
};

/// The relation of two positions of one root (§2.3.2).
pub const Rel = enum { distinct, related };

/// The relation of two different steps of one parent (§2.3.2): whether
/// they may name one element, and whether the second names every element
/// the first does (`second_prefix`).
pub const StepRel = struct { rel: Rel, second_prefix: bool };

/// A step as the indices that file positions under their parent see it
/// (§2.3.2): `elem` is `[*]`, `other` a field, tuple index or
/// constructor argument.
pub const StepClass = enum(u8) { other, elem, front, back, slice };
pub const step_classes = std.enums.values(StepClass).len;

pub fn stepClass(x: Pos) StepClass {
    return switch (x.kind) {
        .plain => if (Step.fromWord(x.a).kind == .elem) .elem else .other,
        .front => .front,
        .back => .back,
        .slice => .slice,
    };
}

/// §2.3.2, one step: two different steps `x`, `y` of one parent. The one
/// relation the pairwise check (`Frame.related`) and every index that
/// files positions by step (`meetClasses`) answer from.
pub fn stepRel(x: Pos, y: Pos) StepRel {
    const apart: StepRel = .{ .rel = .distinct, .second_prefix = false };
    const cx = stepClass(x);
    const cy = stepClass(y);
    if (cx == .other or cy == .other) return apart;
    // `[*]` names every element, a front, back or slice one's too (#1956).
    if (@import("Mutate.zig").on(.step_elem_apart) and (cx == .elem or cy == .elem)) return apart;
    if (cx == .elem or cy == .elem) return if (cx == cy) apart else .{ .rel = .related, .second_prefix = cy == .elem };
    // Two fronts (or backs) are two indices; a front and a back may meet.
    if (@import("Mutate.zig").on(.step_front_back_apart) and cx != .slice and cy != .slice) return apart;
    if (cx != .slice and cy != .slice) return if (cx == cy) apart else .{ .rel = .related, .second_prefix = false };
    if (@import("Mutate.zig").on(.step_slice_apart)) return apart;
    return switch (cx) {
        .front => if (x.a < y.a) apart else .{ .rel = .related, .second_prefix = true },
        .back => if (x.a < y.b) apart else .{ .rel = .related, .second_prefix = true },
        .slice => switch (cy) {
            .front => if (y.a < x.a) apart else .{ .rel = .related, .second_prefix = false },
            .back => if (y.a < x.b) apart else .{ .rel = .related, .second_prefix = false },
            else => .{ .rel = .related, .second_prefix = true },
        },
        .other, .elem => unreachable,
    };
}

/// The classes of the steps of one parent that may name an element a step
/// of class `c` names, other than that step itself. `stepRel` decides it:
/// some pair of different steps of classes `c` and `d` is related exactly
/// when `d` is listed here (the unit test below checks every pair).
pub fn meetClasses(c: StepClass) []const StepClass {
    return switch (c) {
        .other => &.{},
        .elem => &.{ .front, .back, .slice },
        .front => &.{ .elem, .back, .slice },
        .back => &.{ .elem, .front, .slice },
        .slice => &.{ .elem, .front, .back, .slice },
    };
}

/// The one protocol of every index of positions (`Entries.Within`,
/// `Sweep.Live`, `Stack.Index`): lists per position, list `at_list` for
/// what is at the position and list `stepList(c)` for what is below a step
/// of class `c` of it.
pub const at_list: u32 = 0;
pub const step_lists: u32 = 1 + step_classes;

pub fn stepList(c: StepClass) u32 {
    return 1 + @as(u32, @backingInt(c));
}

/// The lists position `p` is filed under: at `p`, and at each step's
/// parent on its way under the step's class; `ctx.key(position, list)`
/// is called for each.
pub fn fileUnder(pos: []const Pos, p: u32, ctx: anytype) !void {
    try ctx.key(p, at_list);
    var c = p;
    while (pos[c].parent != none) : (c = pos[c].parent) try ctx.key(pos[c].parent, stepList(stepClass(pos[c])));
}

/// The lists a query at position `p` asks: every list at `p` (what is at
/// it or below it), and at each step's parent on its way what is at the
/// parent and what is below a step of a class `meetClasses` lists. So a
/// filed position is met when it is `p`, above or below `p`, or parts from
/// `p` at two steps of classes that may meet: every position
/// `Frame.related` relates to `p` (checked in `Value.zig`'s unit test).
pub fn askFor(pos: []const Pos, p: u32, ctx: anytype) !void {
    for (0..step_lists) |w| try ctx.key(p, @intCast(w));
    var c = p;
    while (pos[c].parent != none) : (c = pos[c].parent) {
        const a = pos[c].parent;
        try ctx.key(a, at_list);
        for (meetClasses(stepClass(pos[c]))) |k| try ctx.key(a, stepList(k));
    }
}

/// Items filed by position under the protocol above (`Sweep.Live`'s
/// parameter buckets, `Stack.Index`'s parameter lists): a filing charges
/// an edge per list, a query an inspection per list asked and per item.
pub const PosLists = struct {
    reg: std.ArrayList(std.ArrayList(u32)) = .empty,

    pub fn deinit(x: *PosLists, g: Allocator) void {
        for (x.reg.items) |*l| l.deinit(g);
        x.reg.deinit(g);
    }

    /// File `item` at position `p`.
    pub fn file(x: *PosLists, g: Allocator, account: *Ids.Account, pos: []const Pos, p: u32, item: u32) Ids.ChargeError!void {
        const Ctx = struct {
            x: *PosLists,
            g: Allocator,
            account: *Ids.Account,
            item: u32,
            pub fn key(c: @This(), at: u32, list: u32) Ids.ChargeError!void {
                try c.account.reserve(.edge, 1);
                const i = step_lists * at + list;
                if (i >= c.x.reg.items.len) try c.x.reg.appendNTimes(c.g, .empty, i + 1 - c.x.reg.items.len);
                try c.x.reg.items[i].append(c.g, c.item);
            }
        };
        try fileUnder(pos, p, Ctx{ .x = x, .g = g, .account = account, .item = item });
    }

    /// Append the items at positions that may be related to `p` (some
    /// more than once) to `out`, and charge an inspection per item of it.
    pub fn ask(x: *const PosLists, g: Allocator, account: *Ids.Account, pos: []const Pos, p: u32, out: *std.ArrayList(u32)) Ids.ChargeError!void {
        const Ctx = struct {
            x: *const PosLists,
            g: Allocator,
            account: *Ids.Account,
            out: *std.ArrayList(u32),
            pub fn key(c: @This(), at: u32, list: u32) Ids.ChargeError!void {
                try c.account.reserve(.inspection, 1);
                const i = step_lists * at + list;
                if (i < c.x.reg.items.len) try c.out.appendSlice(c.g, c.x.reg.items[i].items);
            }
        };
        try askFor(pos, p, Ctx{ .x = x, .g = g, .account = account, .out = out });
        try account.reserve(.inspection, @intCast(out.items.len));
    }
};

const testing = std.testing;

test "meetClasses lists exactly the classes of related steps (§2.3.2)" {
    // Every pair of different steps of one parent, of every class: a related
    // pair's classes are listed by `meetClasses`, both ways, and each listed
    // class is met by some pair (the list is exact).
    var steps: std.ArrayList(Pos) = .empty;
    defer steps.deinit(testing.allocator);
    const plain_words = [_]u32{ Step.elem.word(), Step.contents.word(), (Step{ .kind = .field, .payload = 0 }).word(), (Step{ .kind = .field, .payload = 1 }).word(), (Step{ .kind = .index, .payload = 0 }).word() };
    for (plain_words) |w| try steps.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = .plain, .a = w, .b = 0, .slot = .none });
    for (0..4) |i| for ([_]PKind{ .front, .back }) |k| try steps.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = k, .a = @intCast(i), .b = 0, .slot = .none });
    for (0..4) |i| for (0..4) |j| if (i + j != 0) try steps.append(testing.allocator, .{ .root = 0, .parent = 0, .kind = .slice, .a = @intCast(i), .b = @intCast(j), .slot = .none });
    var met: [step_classes][step_classes]bool = @splat(@splat(false));
    for (steps.items, 0..) |x, i| for (steps.items, 0..) |y, j| {
        if (i == j) continue;
        const r = stepRel(x, y);
        try testing.expectEqual(r.rel, stepRel(y, x).rel);
        if (r.rel != .related) continue;
        const cx = stepClass(x);
        const cy = stepClass(y);
        met[@backingInt(cx)][@backingInt(cy)] = true;
        try testing.expect(std.mem.indexOfScalar(StepClass, meetClasses(cx), cy) != null);
    };
    for (0..step_classes) |c| for (meetClasses(@fromBackingInt(@intCast(c)))) |d| {
        try testing.expect(met[c][@backingInt(d)]);
    };
}
