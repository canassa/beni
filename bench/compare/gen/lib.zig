//! The generator as a library, for `tests/blackbox/compare_gen_test.zig`
//! (docs/design/compare-bench.md §15: beni's printer in the gates).

pub const gen = @import("gen.zig");
pub const print = @import("print/print.zig");
pub const Tree = @import("Tree.zig");
