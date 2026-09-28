//! Whether a test run explores inputs at random.
//!
//! The gates run hand-picked cases: one input per check a reader or a
//! scanner makes, each shown to fail when its check is taken away. Random
//! exploration finds the case nobody thought of, and costs seconds a run
//! every time without finding anything on most of them, so it is opt-in:
//! `zig build fuzz` runs the unit tests with `BENI_FUZZ=1`, and a test that
//! explores calls `skipUnlessFuzzing` first. `BENI_STRESS_ITERATIONS` raises
//! the count of the tests that take it.
//!
//! For tests only.

const std = @import("std");
const testing = std.testing;

/// Skip the calling test unless `BENI_FUZZ` is set to something other than
/// `0`.
pub fn skipUnlessFuzzing() error{SkipZigTest}!void {
    if (!enabled()) return error.SkipZigTest;
}

fn enabled() bool {
    const value = testing.environ.getAlloc(testing.allocator, "BENI_FUZZ") catch return false;
    defer testing.allocator.free(value);
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}
