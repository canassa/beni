//! L10: the paths at which a hold holds a target (`docs/design/ownership-v2.md`
//! §2.8, *Holder entries judged by base leaves*, step 5), split from
//! `Descent` (#1714): read by the plain holders and the best-hold descent.
//!
//! Obligations kept here: O2's resolution half for one hold: every path
//! at which it may hold the target is named, with the relation there.

const std = @import("std");
const Ids = @import("Ids.zig");
const Slots = @import("Slots.zig");
const Dests = @import("Dests.zig");
const Subtree = @import("Subtree.zig");
const MeetRun = @import("MeetRun.zig");
const Value = @import("Value.zig");
const Relation = @import("Relation.zig");
const Distinct = @import("Distinct.zig");

pub const Error = Ids.ChargeError;
const PathId = Ids.PathId;

/// A hold as this file reads it (`Sweep.Hold`'s fields): a leaf of the
/// holder's value, the path it is held at, and whether that path is
/// refined by the target's slots.
pub const Hold = struct { leaf: u32, q: PathId, refine: bool };

/// A path at which a hold holds a target's object, and the relation there.
pub const Held = struct { PathId, Relation.Ov };

/// The paths at which hold `hd` holds an object `target` may be, and
/// the relation there: each `(path, ov)`.
pub fn holdsAt(ev: *Relation.Eval, hd: Hold, target: u32, out: *std.ArrayList(Held)) Error!void {
    const fr = ev.f;
    const g = ev.gpa();
    const o = try Distinct.overlap(ev, hd.leaf, target, true);
    if (o.kind == .no) return;
    if (@import("Mutate.zig").on(.hold_at_off)) return;
    if (!hd.refine) return out.append(g, .{ hd.q, o });
    // The path of the hold: below `q` by the steps from the leaf's
    // position to the slots that meet the target's.
    const lf = fr.leafAt(hd.leaf);
    // The target as leaves of the holder's root: itself, or what a
    // call's leaf comes from (its arrivals).
    var tls: std.ArrayList(u32) = .empty;
    defer tls.deinit(g);
    try sameRoot(ev, lf, target, &tls);
    if (lf.kind == .ref and tls.items.len != 0) {
        const pslot = fr.pos.items[lf.pos].slot;
        var any = false;
        var met: std.ArrayList(u32) = .empty;
        defer met.deinit(g);
        // Each slot, or whole subtree (`↓ts`, §2.3.1), the holder meets: one
        // pass over the target leaf's slots (`MeetRun`).
        for (tls.items) |tli| try MeetRun.meetRun(fr.slots, g, fr.account, fr.places, lf.slots, fr.slots.elems(fr.leafAt(tli).slots), &met);
        for (met.items) |el| {
            const ts = Slots.pathOf(el).int();
            // Held at the leaf's own slot, the hold's path is the target's,
            // a node of its trie when no `⟲` is on its way (§2.8).
            if (hd.q == pslot and !fr.places.paths.col.info[ts].levels) {
                try fr.account.reserve(.path, 1 + fr.places.ancestorAt(.from(ts), fr.places.pathDepth(pslot))[1]);
                if (!fr.places.isPrefix(pslot, .from(ts))) continue;
                try out.append(g, .{ .from(ts), o });
                any = true;
                continue;
            }
            // Held at every slot a route to the target reaches (§2.1, *Every name*).
            var ps: std.ArrayList(u32) = .empty;
            defer ps.deinit(g);
            _ = try Dests.routes(.{ .gpa = g, .account = fr.account, .places = fr.places, .slots = fr.slots }, pslot, .from(ts), hd.q, &ps);
            for (ps.items) |p| {
                try out.append(g, .{ .from(p), o });
                any = true;
            }
        }
        if (any) {
            // The holder's other objects are the target only where its
            // root is not separated: held at the holder's path, under
            // that condition.
            var minus: std.ArrayList(u32) = .empty;
            defer minus.deinit(g);
            for (tls.items) |tli| try minus.append(g, fr.leafAt(tli).slots);
            if (try Subtree.without(fr.slots, g, fr.account, fr.places, lf.slots, minus.items)) |rest| {
                var rl = lf;
                rl.slots = rest;
                // A target of the holder's own root lies in the slots taken
                // out; a symbol keeps a subtree taken out in its set
                // (`Subtree.without` excludes explicit slots only), so the
                // rest is asked apart from it, as distinct slots are (#1742).
                const own = tls.items.len == 1 and tls.items[0] == target;
                const o2 = if (own) try Distinct.apartOf(ev, try fr.leaf(rl), target, true) else try Distinct.overlap(ev, try fr.leaf(rl), target, true);
                if (o2.kind != .no) try out.append(g, .{ hd.q, o2 });
            }
            return;
        }
    }
    try out.append(g, .{ hd.q, o });
}

/// The leaves of target `t` at the holder leaf `lf`'s root: `t`
/// itself when it is of that root, else, while it is a call's or a
/// supply's, what it comes from (§2.9.2 step 4), a few levels deep.
fn sameRoot(ev: *Relation.Eval, lf: Value.Leaf, t: u32, out: *std.ArrayList(u32)) Error!void {
    const fr = ev.f;
    const g = ev.gpa();
    if (lf.kind != .ref) return;
    var cur: std.ArrayList(u32) = .empty;
    defer cur.deinit(g);
    try cur.append(g, t);
    var depth: u32 = 0;
    while (cur.items.len != 0 and depth < 4) : (depth += 1) {
        var next: std.ArrayList(u32) = .empty;
        defer next.deinit(g);
        for (cur.items) |x| {
            try fr.charge(.inspection, 1);
            const xl = fr.leafAt(x);
            if (xl.kind != .ref) continue;
            if (xl.root == lf.root) {
                try out.append(g, x);
                continue;
            }
            const k = fr.roots.items[xl.root].kind;
            if (k == .call or k == .supply) try ev.expand(x, &next);
        }
        std.mem.swap(std.ArrayList(u32), &cur, &next);
    }
}
