//! The `top` edges of a declaration's dispatch leg, for the pre-pass's
//! SCC graph (`Prepass.run`): the edges `check/Edges.zig`'s walk yields,
//! in its order, without its repeats, in time linear in the dispatch table
//! and in what it yields (research report 131).
//!
//! `Edges.declEdges` walks, for each declaration, every term its sites
//! name and the body of every derived row below them, so 3 000 `==` sites
//! over a type of 300 rows walked those rows 3 000 times. Its walk is a
//! depth-first preorder from the roots in order, each term once, so a
//! declaration's `top` edges are the first visits of its `top` terms. A
//! repeated edge does nothing in Tarjan (its second `low` update is the
//! first), so only the first place of each target counts, and that order
//! is what this file keeps.
//!
//! **The sequence of a term**, `seq(t)`: the targets of the first visits
//! of the walk from `t` alone, in order. When the next root's walk starts,
//! every term visited so far had its subtree visited, so the walk from that
//! root visits what the walk from it alone visits, less what was visited,
//! in the same order. So a declaration's edges are its roots' sequences,
//! one after the other, each target at its first place. The same holds for
//! each child of a term `t` on no cycle: no child reaches `t` or a term
//! above it. Terms on a cycle (the rows of recursive types) are grouped by
//! Tarjan over the terms and rows. Inside a group the walk runs as
//! `Edges.termsEdges` runs it, and where it leaves the group the sequence
//! of the term it reaches is spliced in: that term reaches no term of the
//! group, and a target it adds twice is kept at its first place. Every
//! member of a group reaches the same targets (`groupTops`), so a group
//! that reaches at most one gives each member that one, at no cost.
//!
//! **Cost.** Each term's sequence is made once; a term on no cycle merges
//! the sequences of its arguments and of the row it names (each row's once,
//! `rowSeq`), sharing a child's when it adds nothing. A group on a cycle
//! that reaches two or more targets walks the group once for each member
//! that a sequence asks for: the one place that costs more than the table.
//! Safe builds check the answer against `Edges.declEdges` for every
//! declaration of a module of at most `cross_check_terms` terms.
//!
//! Obligations kept here: none (the order of the SCC graph's edges, no abstract value).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Edges = @import("../check/Edges.zig");

const none = std.math.maxInt(u32);

/// The largest dispatch table whose answers safe builds check against
/// `Edges.declEdges`, declaration by declaration.
pub const cross_check_terms: usize = 4096;

pub const Walker = struct {
    gpa: Allocator,
    dt: *const Dispatch,
    /// The module's declarations: a target past them is no edge here.
    n: u32,
    /// Per term: its group (Tarjan over terms and rows).
    group: []u32 = &.{},
    /// Per group: whether it lies on a cycle, its members, and (made on
    /// demand, `none` until then) the targets its members reach.
    cyclic: []bool = &.{},
    gstart: []u32 = &.{},
    gorder: []u32 = &.{},
    tops_start: []u32 = &.{},
    tops_len: []u32 = &.{},
    /// Per term and per row: its sequence in `store`, `none` until made.
    seq_start: []u32 = &.{},
    seq_len: []u32 = &.{},
    row_start: []u32 = &.{},
    row_len: []u32 = &.{},
    store: std.ArrayList(u32) = .empty,
    /// A stamp per declaration: the targets a merge has taken.
    mark: []u32 = &.{},
    stamp: u32 = 0,
    /// A stamp per term: what a walk inside a group has visited.
    seen: []u32 = &.{},
    seen_stamp: u32 = 0,
    work: std.ArrayList(Task) = .empty,
    stack: std.ArrayList(u32) = .empty,
    buf: std.ArrayList(u32) = .empty,

    const Task = struct { t: u32, expanded: bool };

    pub fn init(gpa: Allocator, dt: *const Dispatch, n: u32) Allocator.Error!Walker {
        var w: Walker = .{ .gpa = gpa, .dt = dt, .n = n };
        errdefer w.deinit();
        const nt = dt.terms.len;
        w.seq_start = try gpa.alloc(u32, nt);
        @memset(w.seq_start, none);
        w.seq_len = try gpa.alloc(u32, nt);
        w.row_start = try gpa.alloc(u32, dt.derived.len);
        @memset(w.row_start, none);
        w.row_len = try gpa.alloc(u32, dt.derived.len);
        w.seen = try gpa.alloc(u32, nt);
        @memset(w.seen, 0);
        w.mark = try gpa.alloc(u32, n);
        @memset(w.mark, 0);
        try w.groups();
        return w;
    }

    pub fn deinit(w: *Walker) void {
        const gpa = w.gpa;
        gpa.free(w.group);
        gpa.free(w.cyclic);
        gpa.free(w.gstart);
        gpa.free(w.gorder);
        gpa.free(w.tops_start);
        gpa.free(w.tops_len);
        gpa.free(w.seq_start);
        gpa.free(w.seq_len);
        gpa.free(w.row_start);
        gpa.free(w.row_len);
        gpa.free(w.mark);
        gpa.free(w.seen);
        w.store.deinit(gpa);
        w.work.deinit(gpa);
        w.stack.deinit(gpa);
        w.buf.deinit(gpa);
    }

    /// The derived row term `t` names, when the walk goes into its body.
    fn rowOf(w: *const Walker, t: Dispatch.Term) ?u32 {
        return switch (t) {
            .derived => |use| if (use.index < w.dt.derived.len) use.index else null,
            else => null,
        };
    }

    fn body(w: *const Walker, row: u32) []const Dispatch.TermIndex {
        return w.dt.argsAt(w.dt.derived[row].body);
    }

    /// The target of term `t`'s own edge: a `top` of one of the module's declarations.
    fn target(w: *const Walker, t: Dispatch.Term) ?u32 {
        return switch (t) {
            .top => |use| if (use.decl.int() < w.n) use.decl.int() else null,
            else => null,
        };
    }

    /// Tarjan over the terms and the rows. A row is a node between each
    /// term that names it and its body, so the graph has one edge for each
    /// argument and each entry of a body; a term reaches the same terms as
    /// in the walk. A group lies on a cycle when it has two members or more
    /// (an argument's index is past its owner's, so no term is its own).
    /// Every cycle passes through a row, so Tarjan starts at the rows only;
    /// a term no row reaches lies on no cycle and shares one group of its
    /// own kind, which nothing reads as a group.
    fn groups(w: *Walker) Allocator.Error!void {
        const gpa = w.gpa;
        const dt = w.dt;
        const nt: u32 = @intCast(dt.terms.len);
        const nodes = nt + @as(u32, @intCast(dt.derived.len));
        const index = try gpa.alloc(u32, nodes);
        defer gpa.free(index);
        @memset(index, none);
        const low = try gpa.alloc(u32, nodes);
        defer gpa.free(low);
        const on = try gpa.alloc(bool, nodes);
        defer gpa.free(on);
        @memset(on, false);
        const comp = try gpa.alloc(u32, nodes);
        defer gpa.free(comp);
        var size: std.ArrayList(u32) = .empty;
        defer size.deinit(gpa);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        const Fr = struct { v: u32, cursor: u32 };
        var frames: std.ArrayList(Fr) = .empty;
        defer frames.deinit(gpa);
        var next: u32 = 0;
        for (nt..nodes) |root| {
            if (index[root] != none) continue;
            try frames.append(gpa, .{ .v = @intCast(root), .cursor = 0 });
            while (frames.items.len > 0) {
                const fr = &frames.items[frames.items.len - 1];
                const v = fr.v;
                if (fr.cursor == 0) {
                    index[v] = next;
                    low[v] = next;
                    next += 1;
                    try stack.append(gpa, v);
                    on[v] = true;
                }
                // The next successor of `v`: a term's arguments past it,
                // then the row it names; a row's body.
                var succ: ?u32 = null;
                if (v < nt) {
                    const t = dt.terms[v];
                    const args = dt.argsAt(t.argsOf());
                    while (succ == null and fr.cursor < args.len) : (fr.cursor += 1) {
                        const a = args[fr.cursor].int();
                        if (a > v and a < nt) succ = a;
                    }
                    if (succ == null and fr.cursor == args.len) {
                        fr.cursor += 1;
                        if (w.rowOf(t)) |r| succ = nt + r;
                    }
                } else {
                    const b = w.body(v - nt);
                    while (succ == null and fr.cursor < b.len) : (fr.cursor += 1) {
                        const x = b[fr.cursor].int();
                        if (x < nt) succ = x;
                    }
                }
                if (succ) |s| {
                    if (index[s] == none) {
                        try frames.append(gpa, .{ .v = s, .cursor = 0 });
                    } else if (on[s]) low[v] = @min(low[v], index[s]);
                    continue;
                }
                if (low[v] == index[v]) {
                    const c: u32 = @intCast(size.items.len);
                    var k: u32 = 0;
                    while (true) {
                        const x = stack.pop().?;
                        on[x] = false;
                        comp[x] = c;
                        k += 1;
                        if (x == v) break;
                    }
                    try size.append(gpa, k);
                }
                _ = frames.pop();
                if (frames.items.len > 0) {
                    const p = frames.items[frames.items.len - 1].v;
                    low[p] = @min(low[p], low[v]);
                }
            }
        }
        // The group of the terms no row reaches.
        const alone: u32 = @intCast(size.items.len);
        try size.append(gpa, 1);
        for (comp[0..nt], index[0..nt]) |*c, i| if (i == none) {
            c.* = alone;
        };
        const ng = size.items.len;
        w.group = try gpa.dupe(u32, comp[0..nt]);
        w.cyclic = try gpa.alloc(bool, ng);
        for (size.items, 0..) |k, c| w.cyclic[c] = k > 1;
        // Each group's terms, by a counting sort.
        w.gstart = try gpa.alloc(u32, ng + 1);
        @memset(w.gstart, 0);
        for (w.group) |c| w.gstart[c + 1] += 1;
        for (1..w.gstart.len) |c| w.gstart[c] += w.gstart[c - 1];
        w.gorder = try gpa.alloc(u32, nt);
        const cursor = try gpa.dupe(u32, w.gstart[0..ng]);
        defer gpa.free(cursor);
        for (w.group, 0..) |c, t| {
            w.gorder[cursor[c]] = @intCast(t);
            cursor[c] += 1;
        }
        w.tops_start = try gpa.alloc(u32, ng);
        @memset(w.tops_start, none);
        w.tops_len = try gpa.alloc(u32, ng);
    }

    fn members(w: *const Walker, g: u32) []const u32 {
        return w.gorder[w.gstart[g]..w.gstart[g + 1]];
    }

    fn seqOf(w: *const Walker, t: u32) []const u32 {
        std.debug.assert(w.seq_start[t] != none);
        return w.store.items[w.seq_start[t]..][0..w.seq_len[t]];
    }

    fn rowSeqOf(w: *const Walker, r: u32) []const u32 {
        return w.store.items[w.row_start[r]..][0..w.row_len[r]];
    }

    fn newStamp(w: *Walker) void {
        w.stamp +%= 1;
        if (w.stamp == 0) {
            @memset(w.mark, 0);
            w.stamp = 1;
        }
    }

    fn take(w: *Walker, x: u32) Allocator.Error!void {
        if (w.mark[x] == w.stamp) return;
        w.mark[x] = w.stamp;
        try w.buf.append(w.gpa, x);
    }

    fn takeAll(w: *Walker, xs: []const u32) Allocator.Error!void {
        for (xs) |x| try w.take(x);
    }

    /// `buf` as a new sequence in `store`: its start and length.
    fn keep(w: *Walker) Allocator.Error![2]u32 {
        const at: u32 = @intCast(w.store.items.len);
        try w.store.appendSlice(w.gpa, w.buf.items);
        return .{ at, @intCast(w.buf.items.len) };
    }

    fn need(w: *Walker, c: u32) Allocator.Error!void {
        if (w.seq_start[c] == none) try w.work.append(w.gpa, .{ .t = c, .expanded = false });
    }

    /// The sequence of term `t`, made on demand, what it needs first: a
    /// term on no cycle needs its arguments' and its row's body's; a member
    /// of a group on a cycle the sequences of every term outside the group
    /// that a member names. The groups are ordered by reaching, so this
    /// ends, and each sequence is made once.
    pub fn sequence(w: *Walker, t: u32) Allocator.Error![]const u32 {
        if (w.seq_start[t] != none) return w.seqOf(t);
        const nt = w.dt.terms.len;
        w.work.clearRetainingCapacity();
        try w.work.append(w.gpa, .{ .t = t, .expanded = false });
        while (w.work.pop()) |task| {
            if (w.seq_start[task.t] != none) continue;
            const g = w.group[task.t];
            if (!task.expanded) {
                try w.work.append(w.gpa, .{ .t = task.t, .expanded = true });
                if (!w.cyclic[g]) {
                    const term = w.dt.terms[task.t];
                    for (w.dt.argsAt(term.argsOf())) |a| if (a.int() > task.t and a.int() < nt) try w.need(a.int());
                    if (w.rowOf(term)) |r| if (w.row_start[r] == none) for (w.body(r)) |b| if (b.int() < nt) try w.need(b.int());
                } else if (w.tops_start[g] == none) {
                    for (w.members(g)) |m| {
                        const term = w.dt.terms[m];
                        for (w.dt.argsAt(term.argsOf())) |a| if (a.int() > m and a.int() < nt and w.group[a.int()] != g) try w.need(a.int());
                        if (w.rowOf(term)) |r| for (w.body(r)) |b| if (b.int() < nt and w.group[b.int()] != g) try w.need(b.int());
                    }
                }
                continue;
            }
            if (!w.cyclic[g]) try w.makePlain(task.t) else try w.makeInGroup(task.t);
        }
        return w.seqOf(t);
    }

    /// The sequence of the body of row `r`, for a term on no cycle that names it.
    fn rowSeq(w: *Walker, r: u32) Allocator.Error![]const u32 {
        if (w.row_start[r] == none) {
            const nt = w.dt.terms.len;
            w.newStamp();
            w.buf.clearRetainingCapacity();
            for (w.body(r)) |b| if (b.int() < nt) try w.takeAll(w.seqOf(b.int()));
            const at = try w.keep();
            w.row_start[r] = at[0];
            w.row_len[r] = at[1];
        }
        return w.rowSeqOf(r);
    }

    /// A term on no cycle: its own target, its arguments' sequences, then
    /// its row's, each target at its first place. When one part has every
    /// target, the term shares it.
    fn makePlain(w: *Walker, t: u32) Allocator.Error!void {
        const nt = w.dt.terms.len;
        const term = w.dt.terms[t];
        const own = w.target(term);
        if (w.rowOf(term)) |r| _ = try w.rowSeq(r);
        // The one part with targets, as a span of `store`, or `many`.
        var only: ?[2]u32 = null;
        var many = own != null;
        for (w.dt.argsAt(term.argsOf())) |a| if (a.int() > t and a.int() < nt) {
            const x = a.int();
            if (w.seq_len[x] == 0) continue;
            const span: [2]u32 = .{ w.seq_start[x], w.seq_len[x] };
            if (only) |o| {
                if (o[0] != span[0] or o[1] != span[1]) many = true;
            } else only = span;
        };
        if (w.rowOf(term)) |r| if (w.row_len[r] != 0) {
            const span: [2]u32 = .{ w.row_start[r], w.row_len[r] };
            if (only) |o| {
                if (o[0] != span[0] or o[1] != span[1]) many = true;
            } else only = span;
        };
        if (!many) {
            const span = only orelse [2]u32{ 0, 0 };
            w.seq_start[t] = span[0];
            w.seq_len[t] = span[1];
            return;
        }
        w.newStamp();
        w.buf.clearRetainingCapacity();
        if (own) |x| try w.take(x);
        for (w.dt.argsAt(term.argsOf())) |a| if (a.int() > t and a.int() < nt) try w.takeAll(w.seqOf(a.int()));
        if (w.rowOf(term)) |r| try w.takeAll(w.rowSeqOf(r));
        const at = try w.keep();
        w.seq_start[t] = at[0];
        w.seq_len[t] = at[1];
    }

    /// The targets every member of group `g` reaches: its members' own and
    /// the sequences of the terms outside it that they name.
    fn groupTops(w: *Walker, g: u32) Allocator.Error![]const u32 {
        if (w.tops_start[g] == none) {
            const nt = w.dt.terms.len;
            w.newStamp();
            w.buf.clearRetainingCapacity();
            for (w.members(g)) |m| if (w.target(w.dt.terms[m])) |x| try w.take(x);
            for (w.members(g)) |m| {
                const term = w.dt.terms[m];
                for (w.dt.argsAt(term.argsOf())) |a| if (a.int() > m and a.int() < nt and w.group[a.int()] != g) try w.takeAll(w.seqOf(a.int()));
                if (w.rowOf(term)) |r| for (w.body(r)) |b| if (b.int() < nt and w.group[b.int()] != g) try w.takeAll(w.seqOf(b.int()));
            }
            const at = try w.keep();
            w.tops_start[g] = at[0];
            w.tops_len[g] = at[1];
        }
        return w.store.items[w.tops_start[g]..][0..w.tops_len[g]];
    }

    /// Member `e` of a group on a cycle: the walk from `e` alone, as
    /// `Edges.termsEdges` runs it, inside the group; a term outside it is
    /// its sequence, spliced. A group that reaches at most one target
    /// gives each member that one: the walk from any member reaches all.
    fn makeInGroup(w: *Walker, e: u32) Allocator.Error!void {
        const g = w.group[e];
        const tops = try w.groupTops(g);
        if (tops.len <= 1) {
            w.seq_start[e] = w.tops_start[g];
            w.seq_len[e] = w.tops_len[g];
            return;
        }
        const nt = w.dt.terms.len;
        w.seen_stamp +%= 1;
        if (w.seen_stamp == 0) {
            @memset(w.seen, 0);
            w.seen_stamp = 1;
        }
        w.newStamp();
        w.buf.clearRetainingCapacity();
        w.stack.clearRetainingCapacity();
        try w.stack.append(w.gpa, e);
        while (w.stack.pop()) |i| {
            if (i >= nt or w.seen[i] == w.seen_stamp) continue;
            w.seen[i] = w.seen_stamp;
            if (w.group[i] != g) {
                try w.takeAll(w.seqOf(i));
                continue;
            }
            const term = w.dt.terms[i];
            if (w.target(term)) |x| try w.take(x);
            if (w.rowOf(term)) |r| {
                const b = w.body(r);
                var k = b.len;
                while (k > 0) {
                    k -= 1;
                    try w.stack.append(w.gpa, b[k].int());
                }
            }
            const args = w.dt.argsAt(term.argsOf());
            var k = args.len;
            while (k > 0) {
                k -= 1;
                if (args[k].int() <= i) continue;
                try w.stack.append(w.gpa, args[k].int());
            }
        }
        const at = try w.keep();
        w.seq_start[e] = at[0];
        w.seq_len[e] = at[1];
    }

    /// Declaration `di`'s `top` edges of the dispatch leg, appended to
    /// `out`, each target at its first place: the sites' callee and
    /// evidence roots in order, each root's sequence.
    pub fn declTops(w: *Walker, bir: *const Bir, di: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
        const d = bir.decls[di];
        const nt = w.dt.terms.len;
        const sites = w.dt.sitesIn(d.inst_start.int(), d.inst_end.int());
        // Every root's sequence first: making one uses the stamps.
        for (sites) |site| {
            if (site.callee.unwrap()) |c| if (c.int() < nt) {
                _ = try w.sequence(c.int());
            };
            for (w.dt.argsAt(site.evidence)) |r| if (r.int() < nt) {
                _ = try w.sequence(r.int());
            };
        }
        w.newStamp();
        for (sites) |site| {
            if (site.callee.unwrap()) |c| if (c.int() < nt) try w.emit(c.int(), out);
            for (w.dt.argsAt(site.evidence)) |r| if (r.int() < nt) try w.emit(r.int(), out);
        }
    }

    fn emit(w: *Walker, t: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
        for (w.seqOf(t)) |x| {
            if (w.mark[x] == w.stamp) continue;
            w.mark[x] = w.stamp;
            try out.append(w.gpa, x);
        }
    }
};

/// Safe builds: `edges`, the targets of declaration `di` that the pre-pass
/// collected, each at its first place, are `Edges.declEdges`' `top`
/// targets of the module's declarations, each at its first place.
pub fn crossCheck(gpa: Allocator, bir: *const Bir, dt: *const Dispatch, di: u32, edges: []const u32) Allocator.Error!void {
    if (!std.debug.runtime_safety) return;
    const n: u32 = @intCast(bir.decls.len);
    var legs: std.ArrayList(Edges.Edge) = .empty;
    defer legs.deinit(gpa);
    try Edges.declEdges(&legs, gpa, bir, dt, di);
    // Per declaration: its place among the first places of `Edges`' targets, and of ours.
    const want = try gpa.alloc(u32, n);
    defer gpa.free(want);
    @memset(want, none);
    var count: u32 = 0;
    for (legs.items) |e| switch (e) {
        .top => |x| if (x < n and want[x] == none) {
            want[x] = count;
            count += 1;
        },
        else => {},
    };
    const got = try gpa.alloc(bool, n);
    defer gpa.free(got);
    @memset(got, false);
    var place: u32 = 0;
    for (edges) |x| {
        if (got[x]) continue;
        got[x] = true;
        if (want[x] != place) std.debug.panic("ownership: the pre-pass's dispatch edges of declaration {d} are not the walk's", .{di});
        place += 1;
    }
    if (place != count) std.debug.panic("ownership: the pre-pass's dispatch edges of declaration {d} are not the walk's", .{di});
}
