//! L12: the codes of a group solved on their own, and a group's cycles of
//! local functions (`docs/design/ownership-v2.md` §2.12, §7.6 item 6), split
//! from `Groups`.
//!
//! Obligations kept here: none of §2.14's directly (`Groups` checks what a
//! code solved on its own read).

const std = @import("std");
const Ids = @import("Ids.zig");
const Walk = @import("Walk.zig");

const none: u32 = Ids.none_int;

/// Whether some local function of the group's declarations calls itself or
/// another through a cycle of local functions (§2.12: a block's local
/// functions that call each other are a group). The prepass's `recursive`
/// bit is per top-level declaration and misses these. A reference to a local
/// function inside a code, or inside a lambda nested in it, is an edge.
pub fn localCycle(mod: anytype, rs: anytype, codes: []const u32) !bool {
    const gpa = mod.gpa;
    const bir = mod.in.bir;
    const fr = mod.prepass.enclosing_frame;
    var locals: std.ArrayList(u32) = .empty;
    defer locals.deinit(gpa);
    for (codes) |id| if (mod.codes.items[id].kind == .local) try locals.append(gpa, id);
    if (locals.items.len == 0) return false;
    const n = locals.items.len;
    const adj = try gpa.alloc(std.ArrayList(u32), n);
    defer {
        for (adj) |*a| a.deinit(gpa);
        gpa.free(adj);
    }
    for (adj) |*a| a.* = .empty;
    for (rs) |r| {
        const d = bir.decls[r.decl];
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) {
            if (bir.instTag(@fromBackingInt(i)) != .local) continue;
            const l = bir.instData(@fromBackingInt(i)).lhs;
            if (l >= d.locals_end - d.locals_start) continue;
            const binding = bir.locals[d.locals_start + l].inst.int();
            const target = for (locals.items, 0..) |id, k| {
                if (mod.codes.items[id].decl == r.decl and mod.codes.items[id].inst == binding) break k;
            } else continue;
            var f = fr[i];
            var hops: u32 = 0;
            while (f != none and hops < 100_000) : ({
                f = fr[f];
                hops += 1;
            }) {
                for (locals.items, 0..) |id, k| {
                    if (mod.codes.items[id].decl == r.decl and mod.codes.items[id].inst == f) try adj[k].append(gpa, @intCast(target));
                }
            }
        }
    }
    // Depth-first search for a cycle: 0 unseen, 1 on the stack, 2 done.
    const color = try gpa.alloc(u8, n);
    defer gpa.free(color);
    @memset(color, 0);
    const Frame = struct { node: u32, next: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    for (0..n) |root| {
        if (color[root] != 0) continue;
        color[root] = 1;
        try stack.append(gpa, .{ .node = @intCast(root), .next = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next == adj[top.node].items.len) {
                color[top.node] = 2;
                _ = stack.pop();
                continue;
            }
            const to = adj[top.node].items[top.next];
            top.next += 1;
            if (color[to] == 1) return true;
            if (color[to] == 0) {
                color[to] = 1;
                try stack.append(gpa, .{ .node = to, .next = 0 });
            }
        }
    }
    return false;
}

/// What `solveRounds` reads to solve a code on its own: the codes of the
/// group settled already, by their index in its codes.
pub const Settled = struct { settled: []const bool, index_of: *const Ids.FixedDict(1) };

/// Whether code `codes[x]` may be solved on its own now: a lambda or a local
/// function whose walk calls and makes no code of the group that is not
/// settled (`solveRounds` checks what its evaluation reads besides).
pub fn peelable(mod: anytype, codes: []const u32, index_of: *const Ids.FixedDict(1), settled: []const bool, x: u32) !bool {
    const c = mod.codes.items[codes[x]];
    if (c.kind != .lambda and c.kind != .local) return false;
    const w = c.walk orelse return false;
    // The scan is charged: a pass may scan every code again (§4.1).
    try mod.account.reserve(.inspection, @intCast(1 + w.f.calls.items.len + w.closures.items.len));
    for (w.f.calls.items) |cl| if (cl.code != none) if (index_of.get(.{cl.code})) |y| if (!settled[y]) return false;
    for (w.closures.items) |cl| if (cl.code & Walk.fixed_bit == 0) if (index_of.get(.{cl.code})) |y| if (!settled[y]) return false;
    return true;
}
