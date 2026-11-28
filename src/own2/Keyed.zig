//! L12: a worded row of a keyed collection (`Bir.OwnKind.keyed`, core's
//! `Dict`), split from `Groups`. Its rows are the ownership checker v3's
//! (`docs/design/ownership-v3-kernel.md` §12): v2 reads such a row as a
//! `foreign` with no word, as v1 does, so the two judge every program alike.
//!
//! Obligations kept here: none of §2.14's directly (a test of a place).

/// Whether a parameter or the result of a row is a keyed collection's
/// storage: a place of kind list whose head is a `keyed` foreign type.
pub fn row(in: anytype, places: anytype, params: anytype, result: anytype) bool {
    for (0..params.len + 1) |i| {
        const p = if (i < params.len) params[i] else result;
        if (places.kind(p) != .list or places.head(p) >= in.types.entries.len) continue;
        const e = in.types.entries[places.head(p)];
        if (e.kind == .foreign and in.birs[e.module.int()].decl(e.decl).own_kind == .keyed) return true;
    }
    return false;
}
