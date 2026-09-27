//! SplitMix64 (docs/design/compare-bench.md §3.1, §3.2), written here rather
//! than taken from `std.Random`, whose algorithms may change between Zig
//! releases: the generated projects must depend only on this directory.

const Rng = @This();

state: u64,

pub fn init(seed: u64) Rng {
    return .{ .state = seed };
}

/// The stream of one module: `SplitMix64(hash(seed, family, unit))` (§3.2).
pub fn forUnit(seed: u64, family: u32, unit: u32) Rng {
    var h = Rng.init(seed ^ 0x9E3779B97F4A7C15);
    var x = h.next() ^ (@as(u64, family) *% 0xD1B54A32D192ED03);
    h = Rng.init(x);
    x = h.next() ^ (@as(u64, unit) *% 0xABC98388FB8FAC03);
    return Rng.init(mix(x));
}

fn mix(z0: u64) u64 {
    var z = z0;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

pub fn next(r: *Rng) u64 {
    r.state +%= 0x9E3779B97F4A7C15;
    return mix(r.state);
}

/// Uniform in [0, n). `n` must be positive. The modulo bias is irrelevant
/// at the ranges used here and keeps the stream simple to reproduce.
pub fn below(r: *Rng, n: u32) u32 {
    return @intCast(r.next() % n);
}

/// Uniform in [lo, hi], both inclusive.
pub fn range(r: *Rng, lo: u32, hi: u32) u32 {
    return lo + r.below(hi - lo + 1);
}

/// True with probability `percent`/100.
pub fn chance(r: *Rng, percent: u32) bool {
    return r.below(100) < percent;
}

/// An index drawn in proportion to `weights`. At least one must be positive.
pub fn weighted(r: *Rng, weights: []const u32) usize {
    var total: u64 = 0;
    for (weights) |w| total += w;
    var x = r.next() % total;
    for (weights, 0..) |w, i| {
        if (x < w) return i;
        x -= w;
    }
    unreachable;
}

test "the stream is a pure function of the seed" {
    var a = Rng.forUnit(1, 2, 3);
    var b = Rng.forUnit(1, 2, 3);
    var c = Rng.forUnit(1, 2, 4);
    const std = @import("std");
    const x = a.next();
    try std.testing.expectEqual(x, b.next());
    try std.testing.expect(x != c.next());
}
