//! L8: host objects (`docs/design/ownership-v2.md` §2.10, *host objects*):
//! the escapes of a frame's own objects (a site's, a call's, a supply's, a
//! label's answer's), and the leaves the read-off said into a result or a
//! supply, so that it says `host` beside each of those an escape reaches.
//! A parameter's escape is the contract's `escapes` instead.
//!
//! Obligations kept here: none of §2.14's directly (the read-off says
//! `host`; `Resolve` refuses a target that holds one).

const std = @import("std");
const Ids = @import("Ids.zig");
const Value = @import("Value.zig");

const Allocator = std.mem.Allocator;
const Error = Value.Error;

/// Whether leaf `li` is one of the frame's own objects: not a parameter's
/// object, a shared value, `⊤` or a host object.
pub fn own(f: *const Value.Frame, li: u32) bool {
    const l = f.leafAt(li);
    return switch (l.kind) {
        .site, .fresh, .answer => true,
        .ref => f.roots.items[l.root].kind != .param,
        .shared, .top, .host, .recons, .loan => false,
    };
}

/// An own leaf the read-off said into the list `(label, k)` at result path
/// `q` (`wide`: and every slot below), or inside a subtree described once
/// per place (`built`), where the path is not the only one.
pub const Told = struct { leaf: u32, q: u32, label: u32, k: u32, key: u32, wide: bool, built: bool };

/// An own leaf read by no key: `(1, site)`, `(2, call)` for a call's fresh
/// objects, `(4, label)` for a label's answer or result; null otherwise.
fn atomOf(f: *const Value.Frame, li: u32) ?[2]u32 {
    const l = f.leafAt(li);
    return switch (l.kind) {
        .site => .{ 1, l.atom },
        .fresh => .{ 2, l.atom },
        .answer => .{ 4, l.atom },
        .ref => if (f.roots.items[l.root].kind == .cb) .{ 4, f.roots.items[l.root].a } else null,
        else => null,
    };
}

/// A frame's escapes of its own objects, and what the read-off said.
pub const State = struct {
    /// The escapes (indices into the frame's) whose leaf is an own object.
    escs: std.ArrayList(u32) = .empty,
    /// The frame's escapes looked at so far.
    seen: u32 = 0,
    /// `atomOf` each own escape holds, read through the keys of calls.
    atoms: Ids.FixedDict(2) = .{},
    /// An own escape holds something else: each atom is asked of each escape.
    vague: bool = false,
    told: std.ArrayList(Told) = .empty,
    /// `(leaf, q, label, k)` of `told`, each once.
    told_at: Ids.FixedDict(5) = .{},

    pub fn deinit(x: *State, g: Allocator) void {
        x.escs.deinit(g);
        x.atoms.deinit(g);
        x.told.deinit(g);
        x.told_at.deinit(g);
    }

    pub fn tell(x: *State, g: Allocator, t: Told) Error!void {
        if ((try x.told_at.getOrPut(g, .{ t.leaf, t.q, t.label, t.k, t.key })).found_existing) return;
        try x.told.append(g, t);
    }

    /// Take the escapes past those seen (`escs`: the frame's, each with its
    /// `leaf`; `ev` a `Relation.Eval`); the first new one's index in
    /// `x.escs` is returned.
    pub fn sync(x: *State, ev: anytype, escs: anytype) Error!usize {
        const f = ev.f;
        const from = x.escs.items.len;
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(f.gpa);
        var seen: Ids.FixedDict(1) = .{};
        defer seen.deinit(f.gpa);
        while (x.seen < escs.len) : (x.seen += 1) {
            try f.charge(.inspection, 1);
            if (!own(f, escs[x.seen].leaf)) continue;
            try x.escs.append(f.gpa, x.seen);
            try stack.append(f.gpa, escs[x.seen].leaf);
            while (stack.pop()) |y| {
                if ((try seen.getOrPut(f.gpa, .{y})).found_existing or !own(f, y)) continue;
                const l = f.leafAt(y);
                // A label's answer may be what it was handed (§2.9.2).
                if (ev.expandable(l)) try ev.expand(y, &stack) else if (atomOf(f, y)) |k| {
                    _ = try x.atoms.getOrPut(f.gpa, k);
                    if (k[0] == 4) x.vague = true;
                } else x.vague = true;
            }
        }
        return from;
    }

    /// Whether one of the escapes `escs[from..]` taken reaches leaf `li`, an
    /// own object read by no key (`overlap`: the one relation over `ev`).
    pub fn reaches(x: *const State, ev: anytype, escs: anytype, from: usize, li: u32, overlap: anytype) Error!bool {
        if (@import("Mutate.zig").on(.host_reach_off)) return false;
        if (from == x.escs.items.len) return false;
        if (x.vague) {
            for (x.escs.items[from..]) |ei| if ((try overlap(ev, li, escs[ei].leaf, false)).kind != .no) return true;
            return false;
        }
        return if (atomOf(ev.f, li)) |k| x.atoms.get(k) != null else true;
    }
};
