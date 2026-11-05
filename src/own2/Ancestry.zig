//! L6: region ancestry (`docs/design/ownership-v2.md` §2.5, §4.1), split
//! from `Liveness`: the fixed-word form of compatibility for one PAIR of
//! points, where `Liveness`'s range descent asks it of a range. Binary
//! lifting over the region tree, LCA in O(log depth) with no allocation per
//! query (§4.1's at-most-64-step ancestry), its slots in the region atom's
//! source-settlement lane.
//!
//! Obligations kept here: none of §2.14's directly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Regions = @import("Regions.zig");

const RegionId = Ids.RegionId;
const Charge = Ids.Charge;
const Error = Ids.ChargeError;

/// Binary lifting over a region tree: `compatible` for one pair of points
/// in O(log depth) fixed-word steps and no allocation (§4.1's ancestry
/// query). Built once per frame, `levels · regions` words.
pub const Ancestry = struct {
    up: []RegionId = &.{},
    depth: []u32 = &.{},
    levels: u32 = 0,

    pub fn deinit(a: *Ancestry, gpa: Allocator) void {
        gpa.free(a.up);
        gpa.free(a.depth);
    }

    /// `levels = ⌈log₂(max depth + 2)⌉` slots per region, each one record
    /// in the region's source-settlement lane (§4.1: "precompute 32
    /// binary-lifting ancestor slots per region … charging them to its
    /// source settlement lane"), keyed by the region id, unique in the
    /// declaration whose tree this is, and `phase`.
    pub fn build(gpa: Allocator, account: *Ids.Account, phase: Ids.Phase, regions: *const Regions.Tree) Error!Ancestry {
        const n = regions.count();
        var a: Ancestry = .{};
        errdefer a.deinit(gpa);
        a.depth = try gpa.alloc(u32, n);
        var max_depth: u32 = 0;
        for (0..n) |i| {
            a.depth[i] = regions.get(.from(@intCast(i))).depth;
            max_depth = @max(max_depth, a.depth[i]);
        }
        a.levels = std.math.log2_int_ceil(u32, max_depth + 2);
        a.up = try gpa.alloc(RegionId, n * a.levels);
        for (0..n) |i| {
            const charge: Charge = .in(account, .{ .atom = Ids.atom_region_bit | @as(u32, @intCast(i)), .role = .transfer_settlement, .phase = phase });
            try charge.reserve(gpa, .region, a.levels);
            a.up[i * a.levels] = regions.get(.from(@intCast(i))).parent;
        }
        var k: u32 = 1;
        while (k < a.levels) : (k += 1) {
            for (0..n) |i| {
                const mid = a.up[i * a.levels + k - 1];
                a.up[i * a.levels + k] = if (mid == .none) .none else a.up[mid.int() * a.levels + k - 1];
            }
        }
        return a;
    }

    fn lift(a: *const Ancestry, r: RegionId, by: u32) RegionId {
        var at = r;
        var rest = by;
        var k: u32 = 0;
        while (rest > 0 and at != .none) : (k += 1) {
            if (rest & 1 == 1) at = a.up[at.int() * a.levels + k];
            rest >>= 1;
        }
        return at;
    }

    /// The children of the LCA on the way to `ra` and `rb` (`.none` when
    /// one is the ancestor of the other), §2.5's test: incompatible exactly
    /// when both are arms of one case and differ.
    pub fn compatible(a: *const Ancestry, regions: *const Regions.Tree, ra: RegionId, rb: RegionId) bool {
        var x = ra;
        var y = rb;
        if (a.depth[x.int()] > a.depth[y.int()]) {
            x = a.lift(x, a.depth[x.int()] - a.depth[y.int()] - 1);
            if (a.up[x.int() * a.levels] == y) return true;
            x = a.up[x.int() * a.levels];
        } else if (a.depth[y.int()] > a.depth[x.int()]) {
            y = a.lift(y, a.depth[y.int()] - a.depth[x.int()] - 1);
            if (a.up[y.int() * a.levels] == x) return true;
            y = a.up[y.int() * a.levels];
        }
        if (x == y) return true;
        // Same depth, distinct: lift both while their ancestors differ.
        var k = a.levels;
        while (k > 0) {
            k -= 1;
            const ux = a.up[x.int() * a.levels + k];
            const uy = a.up[y.int() * a.levels + k];
            if (ux != uy) {
                x = ux;
                y = uy;
            }
        }
        // `x` and `y` are the children below the LCA.
        const kx = regions.get(x).kind;
        const ky = regions.get(y).kind;
        if (!(kx == .arm or kx == .virtual_arm) or !(ky == .arm or ky == .virtual_arm)) return true;
        const rx = regions.get(x);
        const ry = regions.get(y);
        return !(rx.case_inst == ry.case_inst and rx.arm != ry.arm);
    }

    pub fn compatiblePoints(a: *const Ancestry, regions: *const Regions.Tree, p: u32, q: u32) bool {
        return a.compatible(regions, regions.regionOf(p), regions.regionOf(q));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Prepass = @import("Prepass.zig");

const case_module_text =
    \\module Main exposing (g)
    \\
    \\g : Int, List Int → Int
    \\g n xs =
    \\    case n of
    \\        0 →
    \\            case xs of
    \\                [] → 1
    \\                [ x, …rest ] → x + List.length rest
    \\        _ →
    \\            let
    \\                k = n * 2
    \\            in
    \\            case k of
    \\                4 → k
    \\                _ → n
    \\
;

test "ancestry: binary lifting agrees with the region tree's climb on a lowered module, in the region's lane" {
    const gpa = testing.allocator;
    var lowered = try Prepass.lowerSource(case_module_text);
    defer lowered.deinit();
    const bir = &lowered.bir;
    const d = bir.decls[lowered.declNamed("g")];
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    var tree = try Regions.build(gpa, &account, .inference, bir, d, null);
    defer tree.deinit(gpa);
    var anc = try Ancestry.build(gpa, &account, .inference, &tree);
    defer anc.deinit(gpa);
    try testing.expect(tree.count() >= 5);
    // The region's source-settlement lane: `base₂` and the ancestor slots.
    try testing.expectEqual(anc.levels + 1, account.laneUsed(.{ .atom = Ids.atom_region_bit, .role = .transfer_settlement }));
    try testing.expectEqual(@as(u32, 0), account.laneUsed(.{ .atom = 0, .role = .direct_demand_query }));
    var p = d.inst_start.int();
    while (p < d.inst_end.int()) : (p += 1) {
        var q = d.inst_start.int();
        while (q < d.inst_end.int()) : (q += 1) {
            try testing.expectEqual(tree.compatible(p, q), anc.compatiblePoints(&tree, p, q));
        }
    }
}
