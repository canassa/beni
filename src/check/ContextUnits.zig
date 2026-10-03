//! The units of `Contexts.zig`'s fixpoint (checker-v2.md §11.2, §11.5): the
//! strongly connected components of the module's "payload mentions" graph
//! over its own types, and their completion as a `via` target's mentions
//! arrive (`complete`). Kept apart from `Contexts.zig` to hold both under
//! `checker-v2.md` §19.1's 1 500 lines; the functions are still
//! `Contexts`' own, re-exported there by name.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Scc = @import("Scc.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Solve = @import("Solve.zig");
const Walk = @import("Walk.zig");

const Contexts = @import("Contexts.zig");
const Var = TypeStore.Var;
const Error = Contexts.Error;

/// The units of the declared edges: one per strongly connected component
/// of derived types, members ascending (P1). `complete` merges units as
/// `via` targets' mentions arrive; nothing renumbers a unit.
pub fn initUnits(c: *Contexts) Error!void {
    const scratch = c.cx.scratch;
    const units = try Scc.sccGroups(scratch, c.count, c.edges, c.edge_start);
    for (0..units.starts.len - 1) |u| {
        const members = units.order[units.starts[u]..units.starts[u + 1]];
        if (members.len == 0 or !c.derives(members[0])) continue;
        std.mem.sort(u32, members, {}, std.sort.asc(u32));
        _ = try c.pushUnit(members);
    }
}

/// A new unit of `members` (ascending): its members' unit and slot, and its
/// per-unit state, fresh.
pub fn pushUnit(c: *Contexts, members: []const u32) Error!u32 {
    const scratch = c.cx.scratch;
    const u: u32 = @intCast(c.unit_len.items.len);
    try c.unit_start.append(scratch, @intCast(c.unit_members.items.len));
    try c.unit_len.append(scratch, @intCast(members.len));
    try c.unit_members.appendSlice(scratch, members);
    try c.memo_list.append(scratch, .none);
    try c.memo_gen_list.append(scratch, 0);
    try c.replay_list.append(scratch, .{});
    try c.seen_list.append(scratch, 0);
    c.memo = c.memo_list.items;
    c.memo_gen = c.memo_gen_list.items;
    c.replay_of = c.replay_list.items;
    c.seen = c.seen_list.items;
    for (members, 0..) |t, i| {
        c.unit_of[t] = u;
        c.member_of[t] = @intCast(i);
    }
    return u;
}

/// Unit `u`'s members, ascending (a slot is `member * 2 + kind`). The
/// slice moves when a unit is added: copy it across anything that can
/// complete the graph.
pub fn membersOf(c: *const Contexts, u: u32) []const u32 {
    return c.unit_members.items[c.unit_start.items[u]..][0..c.unit_len.items[u]];
}

pub fn unitCount(c: *const Contexts) u32 {
    return @intCast(c.unit_len.items.len);
}

/// Record that local type `t` reads schema `decl`'s payloads, whose `via`
/// targets it mentions once the schema's group has inferred them
/// (`complete`).
pub fn noteVia(c: *Contexts, t: u32, decl: u32) Error!void {
    if (c.has_via.len == 0 or !c.has_via[decl]) return;
    try c.via_refs.append(c.cx.scratch, .{ t, decl });
}

/// Make the unit graph exact around `seeds` before a unit of theirs runs,
/// or their §11.4 gate is walked (§11.5): walking the local types reachable from them, every schema with
/// a `via` that one of them reads is demanded (§10.2) by the frame that
/// asked, and once its group is done its `via` targets' mentions become
/// edges of every type that reads it, and the walk goes on through them.
/// Only what the seeds reach is demanded — a comparison that needs no
/// schema nests none, whatever the declaration order — and the units the
/// new edges close into cycles are merged, locally. Whether every schema
/// reached is done (false while one is in flight): only then are the types
/// reached marked `completed`, and a later walk stops at them. So each type
/// is walked, and each `via` target read, once in the module, however many
/// comparisons reach it.
pub fn complete(s: *Solve, seeds: []const u32) Error!bool {
    const c = &s.contexts;
    if (c.via_refs.items.len == 0) return true;
    const cx = c.cx;
    const scratch = cx.scratch;
    if (c.refs_by_type.len == 0) try c.indexVias();
    c.reach_walk += 1;
    const stamp = c.reach_walk;
    var region: std.ArrayList(u32) = .empty;
    defer region.deinit(scratch);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(scratch);
    for (seeds) |t| {
        if (c.completed[t] or c.reached[t] == stamp) continue;
        c.reached[t] = stamp;
        try stack.append(scratch, t);
    }
    var added = false;
    var exact = true;
    while (stack.pop()) |t| {
        try region.append(scratch, t);
        for (c.edges[c.edge_start[t]..c.edge_start[t + 1]]) |to| try c.reach(&stack, to, stamp);
        var k: usize = 0;
        while (k < c.extra_adj[t].items.len) : (k += 1) try c.reach(&stack, c.extra_adj[t].items[k], stamp);
        for (c.via_refs.items[c.refs_by_type[t]..c.refs_by_type[t + 1]]) |r| {
            const decl = r[1];
            if (c.via_added[decl]) continue;
            if (s.groups.statusOf(decl) == .unchecked) {
                const d = cx.bir.decls[decl];
                _ = try s.groups.demand(s, decl, d.inst_start, cx.bir.symbol(d.name));
            }
            if (c.via_added[decl]) continue;
            if (s.groups.statusOf(decl) != .done) {
                exact = false;
                continue;
            }
            c.via_added[decl] = true;
            for (c.referrers.items[c.refs_by_decl[decl]..c.refs_by_decl[decl + 1]]) |from| {
                const before = c.extra_adj[from].items.len;
                if (!try c.viaEdges(from, decl)) continue;
                added = true;
                if (c.reached[from] != stamp) continue;
                for (c.extra_adj[from].items[before..]) |to| try c.reach(&stack, to, stamp);
            }
        }
    }
    if (added) try c.merge(region.items, stamp);
    if (exact) for (region.items) |t| {
        c.completed[t] = true;
    };
    return exact;
}

pub fn reach(c: *Contexts, stack: *std.ArrayList(u32), t: u32, stamp: u32) Error!void {
    if (c.completed[t] or c.reached[t] == stamp) return;
    c.reached[t] = stamp;
    try stack.append(c.cx.scratch, t);
}

/// The units a `complete` walk's new edges closed into cycles, merged: the
/// strongly connected components of the region it walked (`stamp`), each
/// one that spans more than one unit made one new unit, its units retired.
/// No cycle can pass through a type outside the region — a completed type
/// reaches no type that gained an edge — so the region's components are the
/// graph's. A unit in a run, or memoised permanently, never merges: every
/// `via` its members reach was added before it ran (asserted in a safety build); one
/// memoised for its generation, past a schema then in flight, may.
pub fn merge(c: *Contexts, region: []const u32, stamp: u32) Error!void {
    const scratch = c.cx.scratch;
    const n: u32 = @intCast(region.len);
    // The region as a graph of its own, by local index.
    for (region, 0..) |t, i| c.local_index[t] = @intCast(i);
    const starts = try scratch.alloc(u32, n + 1);
    defer scratch.free(starts);
    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(scratch);
    for (region, 0..) |t, i| {
        starts[i] = @intCast(edges.items.len);
        for (c.edges[c.edge_start[t]..c.edge_start[t + 1]]) |to| {
            if (c.reached[to] == stamp and !c.completed[to]) try edges.append(scratch, c.local_index[to]);
        }
        for (c.extra_adj[t].items) |to| {
            if (c.reached[to] == stamp and !c.completed[to]) try edges.append(scratch, c.local_index[to]);
        }
    }
    starts[n] = @intCast(edges.items.len);
    const sccs = try Scc.sccGroups(scratch, n, edges.items, starts);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(scratch);
    for (0..sccs.starts.len - 1) |k| {
        const comp = sccs.order[sccs.starts[k]..sccs.starts[k + 1]];
        if (comp.len < 2) continue;
        members.clearRetainingCapacity();
        const first_unit = c.unit_of[region[comp[0]]];
        var spans = false;
        for (comp) |i| {
            const t = region[i];
            if (!c.derives(t)) continue;
            try members.append(scratch, t);
            if (c.unit_of[t] != first_unit) spans = true;
        }
        if (!spans) continue;
        std.mem.sort(u32, members.items, {}, std.sort.asc(u32));
        for (members.items) |t| {
            const old = c.unit_of[t];
            if (std.debug.runtime_safety) {
                std.debug.assert(c.memo[old] != .permanent);
                for (c.runs.items) |r| std.debug.assert(r.unit != old);
            }
            c.unit_len.items[old] = 0;
        }
        _ = try c.pushUnit(members.items);
        c.rebuilds += 1;
    }
}

/// `via_refs` sorted by type (`refs_by_type`, a CSR over it), and each
/// schema's readers (`referrers`, a CSR by declaration).
pub fn indexVias(c: *Contexts) Error!void {
    const scratch = c.cx.scratch;
    const n = c.count;
    const decls = c.cx.bir.decls.len;
    std.mem.sort([2]u32, c.via_refs.items, {}, struct {
        fn lessThan(_: void, a: [2]u32, b: [2]u32) bool {
            return if (a[0] != b[0]) a[0] < b[0] else a[1] < b[1];
        }
    }.lessThan);
    c.refs_by_type = try scratch.alloc(u32, n + 1);
    @memset(c.refs_by_type, 0);
    c.refs_by_decl = try scratch.alloc(u32, decls + 1);
    @memset(c.refs_by_decl, 0);
    for (c.via_refs.items) |r| {
        c.refs_by_type[r[0] + 1] += 1;
        c.refs_by_decl[r[1] + 1] += 1;
    }
    for (1..n + 1) |i| c.refs_by_type[i] += c.refs_by_type[i - 1];
    for (1..decls + 1) |i| c.refs_by_decl[i] += c.refs_by_decl[i - 1];
    c.referrers = .empty;
    try c.referrers.resize(scratch, c.via_refs.items.len);
    const cursor = try scratch.dupe(u32, c.refs_by_decl[0..decls]);
    defer scratch.free(cursor);
    for (c.via_refs.items) |r| {
        c.referrers.items[cursor[r[1]]] = r[0];
        cursor[r[1]] += 1;
    }
}

/// Local type `from`'s edges to the own types schema `decl`'s program
/// payloads mention (its `via` targets among them), as the schema's done
/// group left them: whether any edge is new. A stamp per call keeps it
/// linear in `from`'s edges and the payloads.
pub fn viaEdges(c: *Contexts, from: u32, decl: u32) Error!bool {
    const cx = c.cx;
    const store = cx.store;
    const scratch = cx.scratch;
    c.edge_walk += 1;
    const has = c.edge_walk;
    for (c.edges[c.edge_start[from]..c.edge_start[from + 1]]) |to| c.edge_seen[to] = has;
    for (c.extra_adj[from].items) |to| c.edge_seen[to] = has;
    var roots: std.ArrayList(Var) = .empty;
    defer roots.deinit(scratch);
    const program = cx.types.ofSchemaDecl(cx.module, @fromBackingInt(@intCast(decl)), .type);
    if (program != .none and cx.types.entry(program).kind == .adt) {
        try cx.schemas.payloads(decl, .type, &roots, scratch);
    } else {
        try roots.append(scratch, cx.schemas.endpoints[decl].program);
    }
    const seen = store.nextMark();
    var grew = false;
    while (roots.pop()) |next| {
        const root = store.find(next);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        switch (store.content(root)) {
            .structure => |flat| switch (flat) {
                .app => |a| if (c.local(a.type)) |to| {
                    if (c.derives(to) and c.edge_seen[to] != has) {
                        c.edge_seen[to] = has;
                        try c.extra_adj[from].append(scratch, to);
                        grew = true;
                    }
                },
                else => {},
            },
            else => {},
        }
        var i: u32 = 0;
        while (Walk.child(store, root, i, .structural)) |ch| : (i += 1) try roots.append(scratch, ch);
    }
    return grew;
}

/// Local type `t`'s own `type`s mentioned in declaration `d`'s payloads,
/// through aliases, as edges `t → mentioned`. A schema's references are its
/// payloads' (§11.5): another tagged schema's two nominal endpoints, a
/// record schema's own references (its endpoints are aliases). What a `via`
/// conversion's type mentions is known only once its group is checked: the
/// type records that it reads the schema (`noteVia`), and `complete` adds
/// those mentions as edges before a unit that reaches it runs.
pub fn mentions(c: *Contexts, d: Bir.Decl, edges: *std.ArrayList(u32), from: u32, named: []u32, expanded: []u32) Error!void {
    const bir = c.cx.bir;
    const scratch = c.cx.scratch;
    const types = c.cx.types;
    var pending: std.ArrayList(Bir.Decl) = .empty;
    defer pending.deinit(scratch);
    try pending.append(scratch, d);
    while (pending.pop()) |next| {
        for (bir.declRefs(next)) |ref| {
            if ((ref.kind != .top_type and ref.kind != .top_schema) or ref.a >= bir.decls.len) continue;
            const target = bir.decls[ref.a];
            switch (target.kind) {
                .schema => {
                    const program = types.ofSchemaDecl(c.cx.module, @fromBackingInt(@intCast(ref.a)), .type);
                    if (program == .none or types.entry(program).kind != .adt) {
                        // A record schema's `via` targets are this type's
                        // mentions (`complete`) — not an encoded endpoint's,
                        // whose side holds no conversion target.
                        if (!c.isEncoded(from)) try c.noteVia(from, ref.a);
                        if (expanded[ref.a] == from) continue;
                        expanded[ref.a] = from;
                        try pending.append(scratch, target);
                        continue;
                    }
                    for ([_]Types.TypeId{ program, types.ofSchemaDecl(c.cx.module, @fromBackingInt(@intCast(ref.a)), .encoded) }) |endpoint| {
                        const to = c.local(endpoint) orelse continue;
                        if (named[to] == from) continue;
                        named[to] = from;
                        try edges.append(scratch, to);
                    }
                },
                .type => {
                    const to = c.local(c.cx.types.ofDecl(c.cx.module, @fromBackingInt(@intCast(ref.a)))) orelse continue;
                    if (named[to] == from) continue;
                    named[to] = from;
                    try edges.append(scratch, to);
                },
                .type_alias => {
                    if (expanded[ref.a] == from) continue;
                    expanded[ref.a] = from;
                    try pending.append(scratch, target);
                },
                else => {},
            }
        }
    }
}
