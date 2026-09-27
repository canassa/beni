//! The statistics of docs/design/compare-bench.md §10.6: medians and an
//! ordinary least-squares line over (size, time).

const std = @import("std");

pub const Line = struct { slope: f64, intercept: f64, r2: f64 };

/// The median of `xs`; `xs` is sorted in place.
pub fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

pub fn minimum(xs: []const f64) f64 {
    var m = xs[0];
    for (xs) |x| m = @min(m, x);
    return m;
}

/// OLS of `ys` on `xs`. R² is 1 for a perfect line.
pub fn ols(xs: []const f64, ys: []const f64) Line {
    const n: f64 = @floatFromInt(xs.len);
    var mx: f64 = 0;
    var my: f64 = 0;
    for (xs, ys) |x, y| {
        mx += x;
        my += y;
    }
    mx /= n;
    my /= n;
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    for (xs, ys) |x, y| {
        sxy += (x - mx) * (y - my);
        sxx += (x - mx) * (x - mx);
        syy += (y - my) * (y - my);
    }
    const slope = if (sxx == 0) 0 else sxy / sxx;
    const r2 = if (sxx == 0 or syy == 0) 1 else (sxy * sxy) / (sxx * syy);
    return .{ .slope = slope, .intercept = my - slope * mx, .r2 = r2 };
}

test "a perfect line fits exactly" {
    const l = ols(&.{ 1, 2, 4, 8 }, &.{ 13, 16, 22, 34 });
    try std.testing.expectApproxEqAbs(@as(f64, 3), l.slope, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), l.intercept, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), l.r2, 1e-9);
    var xs = [_]f64{ 5, 1, 3 };
    try std.testing.expectEqual(@as(f64, 3), median(&xs));
    var ys = [_]f64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(f64, 2.5), median(&ys));
}
