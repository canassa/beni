//! The v3 oracle's half of the lowering channel for records
//! (`ownership-v3-kernel.md` §11, item 10): per module, the later reads of a
//! written field that the lowering reads before an accepted update's stores,
//! and the field paths that closures captured, read where each closure is
//! made (§6 rule 3, *A field path a closure captures*).
//! Rows hold only BIR identities, as `own2/Hoists.zig`'s do; the lowering
//! reads each as v1's row (`own/Hoists.zig`, `Read`).

const std = @import("std");

/// A chain of `path_len` field reads at `inst`, from the local `holder` (of
/// declaration `decl`), read whole at `placement`: phase 0 is before that
/// instruction, phase 1 after the update's operands and before its stores,
/// phase 2 after a `let` item. `capture` is the closure made in the
/// holder's frame that the read is inside, or `none` for a read of the body
/// itself; `demand` is the update, or `none` for a closure's read alone.
pub const Read = struct {
    decl: u32,
    demand: u32,
    inst: u32,
    holder: u32,
    path_len: u32,
    placement: u32,
    phase: u32,
    capture: u32 = std.math.maxInt(u32),
};
