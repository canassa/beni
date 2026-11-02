//! EXPERIMENT (`--ownership-slots`): a count of calls into v2's value
//! readers — every public function of `Shape`, `KappaRead` and `Propagate`
//! bumps it — so the slot evaluator can show that its value analysis makes
//! none (ownership-v2.md §8 Q8).
const std = @import("std");

pub var calls: std.atomic.Value(u64) = .init(0);

pub inline fn hit() void {
    _ = calls.fetchAdd(1, .monotonic);
}
