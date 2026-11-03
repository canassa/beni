//! L7: the inline order of the distinct check's entries (`docs/design/ownership-v2.md`
//! §2.9.3, *The rounds' state*): each entry keeps the entry it was expanded from,
//! its place in that expansion and its depth (`par`), and a skew-binary jump
//! pointer (`jump`, made by `Entries.Rounds.add`), so two entries are compared
//! below their common ancestor in O(log depth) steps.
//!
//! Obligations kept here: none of §2.14's (an order).

const Value = @import("Value.zig");

const Frame = Value.Frame;

/// Whether entry `a` comes before `b` in the inline order: by the
/// expansions they came from, compared below their common ancestor.
/// The jump pointers reach it in O(log depth) steps, a record a step.
pub fn before(f: *Frame, p: []const [3]u32, j: []const u32, a: u32, b: u32) !bool {
    const x = try up(f, p, j, a, p[b][2]);
    const y = try up(f, p, j, b, p[a][2]);
    var u = x;
    var v = y;
    // Two entries of one depth have jumps of one depth: jump both while
    // the jumps differ (both still below the common ancestor), else step.
    while (p[u][0] != p[v][0]) {
        try f.charge(.cond, 1);
        if (j[u] != j[v]) {
            u = j[u];
            v = j[v];
        } else {
            u = p[u][0];
            v = p[v][0];
        }
    }
    return p[u][1] < p[v][1];
}

/// `x`'s ancestor at depth `d`, or `x` when it is not deeper.
fn up(f: *Frame, p: []const [3]u32, j: []const u32, x: u32, d: u32) !u32 {
    var at = x;
    while (p[at][2] > d) {
        try f.charge(.cond, 1);
        at = if (p[j[at]][2] >= d) j[at] else p[at][0];
    }
    return at;
}
