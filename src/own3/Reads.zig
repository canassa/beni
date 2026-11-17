//! The v3 oracle's half of the lowering channel for records
//! (`ownership-v3-kernel.md` §11, item 10): per module, the later reads of a
//! written field that the lowering reads before an accepted update's stores.
//! Rows hold only BIR identities, as `own2/Hoists.zig`'s do; the lowering
//! reads each as v1's row (`own/Hoists.zig`, `Read`).

/// A chain of `path_len` field reads at `inst`, from the parameter `holder`
/// (a local of declaration `decl`), read whole at `placement`: phase 1 is
/// after the update's operands and before its stores.
pub const Read = struct {
    decl: u32,
    demand: u32,
    inst: u32,
    holder: u32,
    path_len: u32,
    placement: u32,
    phase: u32,
};
