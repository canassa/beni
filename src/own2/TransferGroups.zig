//! L10: a use below a parameter's leaf, by node
//! (`docs/design/ownership-v2.md` §2.11 item 3, #1412): the groups a call
//! left at a leaf of the caller's own parameter, expanded after the walk
//! into one demand per state (`expandGroups`), and the plain-step `sig`
//! (`Plain`). `Of(Frame)` is this part's methods over the frame
//! `Transfer.zig` declares; `Transfer.zig` binds them by name (§5). It
//! calls `TransferFrame`, `TransferBeside` and `TransferConstruct`
//! (`demand`).
//!
//! Obligations kept here: none of §2.14's directly; its demands are the
//! ones `TransferCall` would make per route (§2.11 item 3, *One demand per
//! state below a parameter's leaf*).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Demands = @import("Demands.zig");
const Calls = @import("Calls.zig");
const Liveness = @import("Liveness.zig");
const Bir = @import("../bir/Bir.zig");
const NodeId = Ids.NodeId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const CondId = Ids.CondId;
const Beside = Calls.Beside;
const Env = Summary.Env;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = Ids.none_int;
const Inst = Bir.Inst;

/// A write route that stopped at an exact, unrefined leaf `leaf` of the
/// caller's own parameter (`Calls.Routes.stops`, §2.11 item 3, #1412): the
/// call it is of (`Frame.call_snaps`), the argument, that argument's whole
/// use, the use node at the leaf and the argument's value there, the steps
/// from the argument down to it, and the place among the frame's demands
/// its demands take (`slot`: the count when it stopped).
pub const Group = struct {
    call: u32,
    param: u32,
    use: NodeId,
    node: NodeId,
    leaf: CellId,
    value: NodeId,
    prefix: Ids.Range,
    slot: u32,
    /// Its demands' run while they are expanded, at the end of `demands`.
    out: Ids.Range = .empty,
};

/// A call with a group: what its demands need after the walk, and its
/// `xreq`, owed by its first demand (§2.11 step 7).
pub const CallSnap = struct {
    point: u32,
    callee_inst: u32,
    /// Its arguments, a run of `Frame.call_args`.
    args: Ids.Range,
    /// Its demands made during the walk: `[first_slot, orig_end)`.
    first_slot: u32,
    orig_end: u32 = 0,
    xreq: CondId = Cond.yes,
};

/// The canonical paths a route walks below a parameter's leaf, and whether
/// a step is plain there (§2.11 item 3, #1412): a step whose `extend` is
/// the path with the step appended, never a fold, a `[*]` or a `⟲`. What
/// `extend` reads to fold is the run of the path's last places on one
/// strongly connected component of the place graph, with which of their
/// steps are `⟲` and which is the root (`sig`, interned): two paths with
/// one `sig` take every step alike, plain or folded.
pub const Plain = struct {
    sigs: Ids.FixedDict(3) = .{},
    sig_of: Ids.FixedDict(1) = .{},
    scratch: std.ArrayList(PathId) = .empty,

    pub fn deinit(p: *Plain, gpa: Allocator) void {
        p.sigs.deinit(gpa);
        p.sig_of.deinit(gpa);
        p.scratch.deinit(gpa);
    }

    fn flags(places: *const Place.Table, at: PathId) u32 {
        if (places.pathParent(at) == .none) return 2;
        return @intFromBool(places.pathStep(at).kind == .level);
    }

    fn intern(p: *Plain, env: Env, parent: u32, at: PathId) Error!u32 {
        try env.charge.reserve(env.gpa, .memo, 1);
        const got = try p.sigs.getOrPut(env.gpa, .{ parent, env.places.pathPlace(at).int(), flags(env.places, at) });
        if (!got.found_existing) got.value_ptr.* = p.sigs.count();
        return got.value_ptr.*;
    }

    /// `path`'s `sig`: 0 off every cycle.
    pub fn sigOf(p: *Plain, env: Env, path: PathId) Error!u32 {
        const places = env.places;
        const here = places.pathPlace(path);
        if (!places.cyclic(here)) return 0;
        if (p.sig_of.get(.{path.int()})) |s| return s;
        p.scratch.clearRetainingCapacity();
        var at = path;
        while (at != .none and places.sccOf(places.pathPlace(at)) == places.sccOf(here)) : (at = places.pathParent(at)) {
            try env.charge.reserve(env.gpa, .path, 1);
            try p.scratch.append(env.gpa, at);
        }
        var s: u32 = 0;
        var i = p.scratch.items.len;
        while (i > 0) {
            i -= 1;
            s = try p.intern(env, s, p.scratch.items[i]);
        }
        (try p.sig_of.getOrPut(env.gpa, .{path.int()})).value_ptr.* = s;
        return s;
    }

    /// The `sig` of `next`, a plain step below a path of `sig` at `here`.
    pub fn nextSig(p: *Plain, env: Env, sig: u32, here: PlaceId, next: PathId) Error!u32 {
        const places = env.places;
        const there = places.pathPlace(next);
        if (!places.cyclic(there)) return 0;
        const s = if (places.cyclic(here) and places.sccOf(here) == places.sccOf(there)) sig else 0;
        const n = try p.intern(env, s, next);
        (try p.sig_of.getOrPut(env.gpa, .{next.int()})).value_ptr.* = n;
        return n;
    }

    /// `path · s` when that is a plain step, else null.
    pub fn step(env: Env, path: PathId, s: Step) Error!?PathId {
        if (s.kind == .level or s.kind == .elem) return null;
        const next = (try env.places.extend(env.gpa, env.charge, path, s)) orelse return null;
        if (env.places.pathParent(next) != path or env.places.pathStep(next).word() != s.word()) return null;
        return next;
    }

    /// Bits of the use node `u` read at `path` (§2.11 item 3, #1412),
    /// memoised by `(u, place, sig)` in `memo`: 1 when every route below it
    /// to a `W` (`below`'s bit 1) takes plain steps only; 2 when one reached
    /// by plain steps writes; 4 when one reached so writes deeply (`S`).
    /// On an explicit stack (#1138); a node met again before it is settled
    /// is no plain route.
    pub fn bits(p: *Plain, env: Env, memo: *Ids.FixedDict(3), below: *Ids.FixedDict(1), u: NodeId, path: PathId) Error!u32 {
        const gpa = env.gpa;
        const shapes = env.shapes;
        const Fr = struct { u: NodeId, path: PathId, sig: u32, expanded: bool };
        var stack: std.ArrayList(Fr) = .empty;
        defer stack.deinit(gpa);
        const sig0 = try p.sigOf(env, path);
        const key0: [3]u32 = .{ u.int(), env.places.pathPlace(path).int(), sig0 };
        if (memo.get(key0)) |b| if (b & 16 != 0) return b & 15;
        try stack.append(gpa, .{ .u = u, .path = path, .sig = sig0, .expanded = false });
        while (stack.pop()) |fr| {
            try env.charge.reserve(gpa, .inspection, 1);
            const here = env.places.pathPlace(fr.path);
            const key: [3]u32 = .{ fr.u.int(), here.int(), fr.sig };
            const got = try memo.getOrPut(gpa, key);
            if (got.found_existing and (got.value_ptr.* & 16 != 0 or !fr.expanded)) continue;
            const kids = shapes.kind(fr.u) == .node;
            if (!fr.expanded) {
                got.value_ptr.* = 0;
                try stack.append(gpa, .{ .u = fr.u, .path = fr.path, .sig = fr.sig, .expanded = true });
                if (kids) {
                    var kt = shapes.overEntries(shapes.get(fr.u).a);
                    while (kt.next()) |k| {
                        if ((below.get(.{k.node.int()}) orelse 3) & 1 == 0) continue;
                        const next = (try step(env, fr.path, k.step)) orelse continue;
                        const s = try p.nextSig(env, fr.sig, here, next);
                        if (memo.get(.{ k.node.int(), env.places.pathPlace(next).int(), s }) == null)
                            try stack.append(gpa, .{ .u = k.node, .path = next, .sig = s, .expanded = false });
                    }
                }
                continue;
            }
            var b: u32 = 1;
            var ct = env.cells.sets.iterate(try shapes.cellsOf(gpa, env.account(), &env.cells.sets, fr.u));
            var w = false;
            var deep = false;
            while (ct.next()) |x| {
                const c: CellId = .from(x.key);
                if (env.cells.origin(c) != .mark) continue;
                switch (env.cells.markOf(c)) {
                    .w => w = true,
                    .deep => deep = true,
                    else => {},
                }
            }
            if (w) b |= if (deep) 6 else 2;
            if (kids) {
                var kt = shapes.overEntries(shapes.get(fr.u).a);
                while (kt.next()) |k| {
                    if ((below.get(.{k.node.int()}) orelse 3) & 1 == 0) continue;
                    const next = (try step(env, fr.path, k.step)) orelse {
                        b &= ~@as(u32, 1);
                        continue;
                    };
                    const s = try p.nextSig(env, fr.sig, here, next);
                    const kb = memo.get(.{ k.node.int(), env.places.pathPlace(next).int(), s }) orelse 0;
                    if (kb & 16 == 0) {
                        b &= ~@as(u32, 1);
                        continue;
                    }
                    b = (b & ~@as(u32, 1)) | (b & kb & 1) | (kb & 6);
                }
            }
            got.value_ptr.* = b | 16;
        }
        return (memo.get(key0) orelse 0) & 15;
    }
};

/// The part of `Transfer.Frame` this file holds, over the frame `Transfer.zig` declares.
pub fn Of(comptime Frame: type) type {
    return struct {
        // ---- a use below a parameter's leaf, by node (§2.11 item 3, #1412) ----------

        /// What the expansion of a frame's groups reads (`expandGroups`).
        const Expand = struct {
            /// `(parameter, j, path)` of every canonical path at or above a
            /// parameter cell the frame's escapes or live holders reach: what
            /// may tell two routes below a leaf apart.
            named: Ids.FixedDict(3) = .{},
            /// One group's own: the paths below its leaf that the call's other
            /// arguments reach and that the later uses of a holder of it read.
            extra: Ids.FixedDict(1) = .{},
            /// The holders with a parameter cell at a path (`at`) and below it
            /// (`under`), by `(parameter, j, path)`: lists in `links`.
            at: Ids.FixedDict(3) = .{},
            under: Ids.FixedDict(3) = .{},
            /// `(holder, next)`.
            links: std.ArrayList([2]u32) = .empty,
            /// Per holder, the last group that read it.
            stamp: []u32 = &.{},
            index: *const Liveness.Index = undefined,
            below: Ids.FixedDict(1) = .{},
            plain_memo: Ids.FixedDict(3) = .{},
            plain: Plain = .{},
            /// A route below the leaf merged into one state:
            /// `(use node, trie node, class, sig, place)`.
            seen: Ids.FixedDict(5) = .{},
            /// `Calls.Routes`' own reading, unmerged.
            exact_seen: Ids.FixedDict(4) = .{},
            entries: std.ArrayList(XEntry) = .empty,
            stack: std.ArrayList(XItem) = .empty,
            steps: std.ArrayList(Step) = .empty,
            use_steps: std.ArrayList(Step) = .empty,
            read_steps: std.ArrayList(Step) = .empty,
            others: std.ArrayList(u32) = .empty,
            /// Whether routes of the group being expanded may be merged.
            merge: bool = true,

            fn deinit(x: *Expand, gpa: Allocator) void {
                x.named.deinit(gpa);
                x.extra.deinit(gpa);
                x.at.deinit(gpa);
                x.under.deinit(gpa);
                x.links.deinit(gpa);
                gpa.free(x.stamp);
                x.below.deinit(gpa);
                x.plain_memo.deinit(gpa);
                x.plain.deinit(gpa);
                x.seen.deinit(gpa);
                x.exact_seen.deinit(gpa);
                x.entries.deinit(gpa);
                x.stack.deinit(gpa);
                x.steps.deinit(gpa);
                x.use_steps.deinit(gpa);
                x.read_steps.deinit(gpa);
                x.others.deinit(gpa);
            }
        };
        const XEntry = struct { step: Step, parent: u32 };
        /// A route below a group's leaf. Unmerged, `Calls.Routes`' item (value,
        /// `stuck`, `free`) with its canonical path (`none` once free); merged,
        /// its state: the deepest trie node it passed (`t`), how it lies to it
        /// (`class`: 0 on it, else 1 + the place of the step that left it), and
        /// the path's `sig`, its path a representative's. `path` is the
        /// parent's until the item is popped, then its own.
        const XItem = struct { node: NodeId, entry: u32, value: NodeId, stuck: bool, free: bool, path: PathId, merged: bool = false, t: PathId = .none, class: u32 = 0, sig: u32 = 0 };

        /// After the walk: each group's routes below its leaf, made into
        /// demands as the call would have made them, one per state of the pair
        /// graph of the callee's use there with what the frame names below the
        /// leaf (§2.11 item 3, *One demand per state below a parameter's leaf*),
        /// each group's put at its place among the demands, so they stay in
        /// evaluation order, and each call's `xreq` on its first demand.
        pub fn expandGroups(f: *Frame, index: *const Liveness.Index) Error!void {
            if (f.groups.items.len == 0) return;
            const gpa = f.gpa;
            var x: Expand = .{ .index = index };
            defer x.deinit(gpa);
            try f.namedPaths(&x);
            const n0 = f.demands.items.len;
            var beside: Beside = .{};
            defer beside.deinit(gpa);
            var at_call: u32 = none;
            for (f.groups.items) |*g| {
                // The children beside the writes' paths, indexed once per call.
                if (g.call != at_call) {
                    beside.deinit(gpa);
                    beside = .{};
                    at_call = g.call;
                }
                const start = f.demands.items.len;
                const kernel = try f.account().enter(gpa, .{ .atom = f.call_snaps.items[g.call].point, .role = .call_view });
                defer f.account().leave(kernel);
                try f.expandGroup(&x, g, &beside);
                g.out = .{ .start = @intCast(start), .len = @intCast(f.demands.items.len - start) };
            }
            // Each group's run at its slot, before the demand made there.
            const all = f.demands.items;
            const out = try gpa.alloc(Demands.Demand, all.len);
            defer gpa.free(out);
            const orig_at = try gpa.alloc(u32, n0);
            defer gpa.free(orig_at);
            const group_at = try gpa.alloc(u32, f.groups.items.len);
            defer gpa.free(group_at);
            var w: u32 = 0;
            var gi: usize = 0;
            var j: u32 = 0;
            while (j <= n0) : (j += 1) {
                while (gi < f.groups.items.len and f.groups.items[gi].slot == j) : (gi += 1) {
                    const g = f.groups.items[gi];
                    group_at[gi] = w;
                    @memcpy(out[w..][0..g.out.len], all[g.out.start..][0..g.out.len]);
                    w += g.out.len;
                }
                if (j < n0) {
                    orig_at[j] = w;
                    out[w] = all[j];
                    w += 1;
                }
            }
            @memcpy(all, out);
            // Each call's `xreq` on its first demand, or the frame's.
            gi = 0;
            for (f.call_snaps.items, 0..) |s, si| {
                var first: u32 = none;
                if (s.first_slot < s.orig_end) first = orig_at[s.first_slot];
                while (gi < f.groups.items.len and f.groups.items[gi].call == si) : (gi += 1) {
                    if (f.groups.items[gi].out.len != 0) first = @min(first, group_at[gi]);
                }
                if (first != none) {
                    const dm = &f.demands.items[first];
                    dm.relies = try f.env.conds.@"and"(gpa, f.env.charge, dm.relies, s.xreq);
                } else f.xreq = try f.env.conds.@"and"(gpa, f.env.charge, f.xreq, s.xreq);
            }
        }

        /// `x.named`: the canonical paths at and above every parameter cell
        /// the frame's escapes reach, and the holders live at a group's call;
        /// and those holders by the paths of their cells (`x.at`, `x.under`).
        /// Another demand's operands are no interferer of a group's demand.
        pub fn namedPaths(f: *Frame, x: *Expand) Error!void {
            const gpa = f.gpa;
            const shapes = f.env.shapes;
            const task = try f.account().enter(gpa, null);
            defer f.account().leave(task);
            for (f.escapes.items) |e| try f.addNamed(x, try shapes.reach(gpa, f.account(), &f.env.cells.sets, e.node));
            const cells = f.env.cells;
            for (f.holders.items, 0..) |h, hi| {
                // Only a holder live at a group's call holds against its demands
                // (§2.8: `(start, end]`); another's value is not read, so no view
                // is forced that the resolver would not force.
                if (!f.aliveAtGroup(h)) continue;
                if (h.value.node == .none) continue;
                const r = try shapes.reach(gpa, f.account(), &cells.sets, h.value.node);
                try f.addNamed(x, r);
                var it = cells.sets.iterate(r);
                while (it.next()) |e| {
                    try f.env.charge.reserve(gpa, .inspection, 1);
                    const c: CellId = .from(e.key);
                    if (cells.origin(cells.base(c)) != .param) continue;
                    const u = (try cells.unrefined(gpa, f.account(), f.env.places, c)) orelse continue;
                    const p = cells.get(u);
                    if (p.origin != .param) continue;
                    try f.linkHolder(x, &x.at, .{ p.a, p.c, p.b }, @intCast(hi));
                    var path = f.env.places.pathParent(.from(p.b));
                    while (path != .none) : (path = f.env.places.pathParent(path)) try f.linkHolder(x, &x.under, .{ p.a, p.c, path.int() }, @intCast(hi));
                }
            }
            x.stamp = try gpa.alloc(u32, f.holders.items.len);
            @memset(x.stamp, none);
        }

        /// Whether a call with a group is in holder `h`'s life `(start, end]`:
        /// the calls are in walk order, so a binary search.
        pub fn aliveAtGroup(f: *const Frame, h: Demands.Holder) bool {
            const snaps = f.call_snaps.items;
            const first = std.sort.partitionPoint(CallSnap, snaps, h.start, struct {
                fn below(start: u32, s: CallSnap) bool {
                    return s.point <= start;
                }
            }.below);
            return first < snaps.len and snaps[first].point <= h.end;
        }

        /// Holder `hi` in `d`'s list at `key`, once: a holder's cells are
        /// listed one after another, so a repeat is the list's head.
        pub fn linkHolder(f: *Frame, x: *Expand, d: *Ids.FixedDict(3), key: [3]u32, hi: u32) Error!void {
            try f.env.charge.reserve(f.gpa, .memo, 1);
            const got = try d.getOrPut(f.gpa, key);
            if (got.found_existing and x.links.items[got.value_ptr.*][0] == hi) return;
            const prev = if (got.found_existing) got.value_ptr.* else none;
            got.value_ptr.* = @intCast(x.links.items.len);
            try x.links.append(f.gpa, .{ hi, prev });
        }

        pub fn addNamed(f: *Frame, x: *Expand, s: SetId) Error!void {
            const cells = f.env.cells;
            var it = cells.sets.iterate(s);
            while (it.next()) |e| {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const c: CellId = .from(e.key);
                if (cells.origin(cells.base(c)) != .param) continue;
                const u = (try cells.unrefined(f.gpa, f.account(), f.env.places, c)) orelse continue;
                const p = cells.get(u);
                if (p.origin != .param) continue;
                var path: PathId = .from(p.b);
                while (path != .none) : (path = f.env.places.pathParent(path)) {
                    try f.env.charge.reserve(f.gpa, .memo, 1);
                    if ((try x.named.getOrPut(f.gpa, .{ p.a, p.c, path.int() })).found_existing) break;
                }
            }
        }

        /// The canonical cell of a parameter cell `c` of parameter `a`, `j`, or
        /// null for another's.
        pub fn paramCell(f: *Frame, c: CellId, a: u32, j: u32) Error!?Cell.Cell {
            const cells = f.env.cells;
            if (cells.origin(cells.base(c)) != .param) return null;
            const u = (try cells.unrefined(f.gpa, f.account(), f.env.places, c)) orelse return null;
            const p = cells.get(u);
            if (p.origin != .param or p.a != a or p.c != j) return null;
            return p;
        }

        pub fn snapArgs(f: *const Frame, snap: u32) []const Inst.Index {
            const r = f.call_snaps.items[snap].args;
            return f.call_args.items[r.start..][0..r.len];
        }

        /// Add `path` to `x.extra` with its ancestors down to `leaf`'s path.
        pub fn addExtra(f: *Frame, x: *Expand, leaf: PathId, path: PathId) Error!void {
            var at = path;
            while (at != .none) : (at = f.env.places.pathParent(at)) {
                try f.env.charge.reserve(f.gpa, .memo, 1);
                if ((try x.extra.getOrPut(f.gpa, .{at.int()})).found_existing or at == leaf) break;
            }
        }

        /// Whether `path` is a node of the group's trie: named by the frame
        /// or by the group.
        fn inTrie(x: *const Expand, a: u32, j: u32, path: PathId) bool {
            return x.named.get(.{ a, j, path.int() }) != null or x.extra.get(.{path.int()}) != null;
        }

        /// One group's trie (`x.extra`, beside the frame's `x.named`) and
        /// whether its routes may be merged (`x.merge`): the paths below the
        /// leaf that the call's other arguments reach, and those the later
        /// uses of a holder of the leaf, of a cell above it or of one below it
        /// read. A later use whose reading of the leaf's paths no path tells
        /// (a call's, which reads through its callee's use; one of a holder
        /// that is no leaf; a pending value that is no leaf) keeps every route
        /// its own, as the call would have made them.
        pub fn groupTrie(f: *Frame, x: *Expand, g: *const Group) Error!void {
            const gpa = f.gpa;
            const shapes = f.env.shapes;
            const places = f.env.places;
            const cells = f.env.cells;
            x.extra.deinit(gpa);
            x.extra = .{};
            x.merge = true;
            const lc = cells.get(g.leaf);
            const lpath: PathId = .from(lc.b);
            try f.addExtra(x, lpath, lpath);
            const arg_insts = f.snapArgs(g.call);
            for (arg_insts, 0..) |a, k| {
                if (k == g.param) continue;
                const v = f.val(a.int()).value;
                if (v.node == .none) continue;
                var it = cells.sets.iterate(try shapes.reach(gpa, f.account(), &cells.sets, v.node));
                while (it.next()) |e| {
                    try f.env.charge.reserve(gpa, .inspection, 1);
                    const p = (try f.paramCell(.from(e.key), lc.a, lc.c)) orelse continue;
                    if (places.isPrefix(lpath, .from(p.b))) try f.addExtra(x, lpath, .from(p.b));
                }
            }
            // The holders with a cell on the leaf's line: at or above it, or below it.
            const gi: u32 = @intCast((@intFromPtr(g) - @intFromPtr(f.groups.items.ptr)) / @sizeOf(Group));
            var at = lpath;
            while (at != .none) : (at = places.pathParent(at)) {
                try f.env.charge.reserve(gpa, .memo, 1);
                if (x.at.get(.{ lc.a, lc.c, at.int() })) |head| try f.holdersOn(x, g, gi, head);
                if (!x.merge) return;
            }
            if (x.under.get(.{ lc.a, lc.c, lpath.int() })) |head| try f.holdersOn(x, g, gi, head);
        }

        /// The holders of a list of `x.links` from `head`, for group `g`
        /// (`groupTrie`), each once a group.
        pub fn holdersOn(f: *Frame, x: *Expand, g: *const Group, gi: u32, head: u32) Error!void {
            var link = head;
            while (link != none) : (link = x.links.items[link][1]) {
                try f.env.charge.reserve(f.gpa, .inspection, 1);
                const hi = x.links.items[link][0];
                if (x.stamp[hi] == gi) continue;
                x.stamp[hi] = gi;
                try f.holderOn(x, g, f.holders.items[hi]);
                if (!x.merge) return;
            }
        }

        /// Holder `h`, whose value holds a cell on group `g`'s leaf's line
        /// (`groupTrie`): the paths below the leaf its later uses read, or
        /// `x.merge` off when no path tells how they read it.
        pub fn holderOn(f: *Frame, x: *Expand, g: *const Group, h: Demands.Holder) Error!void {
            const gpa = f.gpa;
            const shapes = f.env.shapes;
            const places = f.env.places;
            const cells = f.env.cells;
            const lc = cells.get(g.leaf);
            const lpath: PathId = .from(lc.b);
            const point = f.call_snaps.items[g.call].point;
            const n = try shapes.force(gpa, f.account(), h.value.node);
            const leaf = shapes.kind(n) == .leaf;
            if (h.kind == .pending) {
                if (!leaf and h.start < point and h.end >= point) x.merge = false;
                return;
            }
            if (!leaf) {
                // Where a built value holds the leaf, a use reads it through the
                // value's structure: any later use keeps every route its own. A
                // binding lives to its last use, so its end tells.
                if (h.end > point) x.merge = false;
                return;
            }
            var ct = cells.sets.iterate(try shapes.cellsOf(gpa, f.account(), &cells.sets, n));
            while (ct.next()) |e| {
                try f.env.charge.reserve(gpa, .inspection, 1);
                const p = (try f.paramCell(.from(e.key), lc.a, lc.c)) orelse continue;
                const xp: PathId = .from(p.b);
                // The leaf's position in the holder's value: the steps from its
                // cell down to the leaf, when the cell is above it.
                x.use_steps.clearRetainingCapacity();
                const above = places.isPrefix(xp, lpath);
                if (!above and !places.isPrefix(lpath, xp)) continue;
                if (above) {
                    var q = lpath;
                    while (q != xp) : (q = places.pathParent(q)) try x.use_steps.append(gpa, places.pathStep(q));
                    std.mem.reverse(Step, x.use_steps.items);
                }
                const depth = x.use_steps.items.len;
                // The uses on the way down to the leaf hold all of it alike; one
                // that is a call's reads through its callee's use.
                var d: usize = 0;
                while (d <= depth) : (d += 1) {
                    const r = x.index.rangeOf(places, h.who, x.use_steps.items[0..d], d == depth);
                    // The uses of one path and group are one run sorted by point
                    // (`Liveness`): a run is read by its first use and its last
                    // point, never use by use, so a group costs the runs on its
                    // leaf's line, not the holder's earlier uses.
                    var i = r.start;
                    const end = r.start + r.len;
                    while (i < end) {
                        try f.env.charge.reserve(gpa, .inspection, 1);
                        const run_end = x.index.groupEnd(i, end);
                        const u = x.index.get(.from(i));
                        const last = x.index.get(.from(run_end - 1)).point;
                        i = run_end;
                        if (last <= point) continue;
                        if (u.kind == .call and u.use_node != .none) {
                            x.merge = false;
                            return;
                        }
                        if (places.pathDepth(u.path) <= depth) continue;
                        // Below the leaf: the path it reads there.
                        x.read_steps.clearRetainingCapacity();
                        var up = u.path;
                        while (places.pathParent(up) != .none) : (up = places.pathParent(up)) try x.read_steps.append(gpa, places.pathStep(up));
                        var q = xp;
                        var k = x.read_steps.items.len;
                        while (k > 0) {
                            k -= 1;
                            q = (try places.extend(gpa, f.env.charge, q, x.read_steps.items[k])) orelse {
                                x.merge = false;
                                return;
                            };
                        }
                        if (places.isPrefix(lpath, q)) try f.addExtra(x, lpath, q);
                    }
                }
            }
        }

        /// Group `g`'s routes below its leaf (`expandGroups`): `Calls.Routes`'
        /// own walk of the use node there paired with the argument's value,
        /// each route a demand, except that a route at a path on no `[*]` or
        /// `⟲` whose every route below to a `W` takes plain steps (`Plain`) is
        /// merged by state: the deepest node of the trie it passed and how it
        /// lies to it. Every route through one state lies to everything the
        /// frame names below the leaf as the others do, so its demand would have
        /// the verdict theirs have; the first met in the walk's order is the
        /// witness, and the others are skipped with what is below them.
        pub fn expandGroup(f: *Frame, x: *Expand, g: *const Group, beside: *Beside) Error!void {
            const gpa = f.gpa;
            const env = f.env;
            const shapes = env.shapes;
            const places = env.places;
            const task = try f.account().enter(gpa, null);
            defer f.account().leave(task);
            try f.groupTrie(x, g);
            const lc = env.cells.get(g.leaf);
            if (try Calls.marksBelow(env, g.node, &x.below) & 1 == 0) return;
            x.seen.deinit(gpa);
            x.seen = .{};
            x.exact_seen.deinit(gpa);
            x.exact_seen = .{};
            x.entries.clearRetainingCapacity();
            x.stack.clearRetainingCapacity();
            try x.stack.append(gpa, .{ .node = g.node, .entry = none, .value = g.value, .stuck = false, .free = false, .path = .from(lc.b) });
            while (x.stack.pop()) |it0| {
                try env.charge.reserve(gpa, .inspection, 1);
                var it = it0;
                if (it.entry != none) {
                    const e = x.entries.items[it.entry];
                    if (it.merged) {
                        const next = (try Plain.step(env, it.path, e.step)) orelse unreachable; // `bits` read it plain
                        it.sig = try x.plain.nextSig(env, it.sig, places.pathPlace(it.path), next);
                        if (it.class == 0) {
                            if (inTrie(x, lc.a, lc.c, next)) it.t = next else it.class = 1 + places.pathPlace(next).int();
                        }
                        it.path = next;
                        if ((try x.seen.getOrPut(gpa, .{ it.node.int(), it.t.int(), it.class, it.sig, places.pathPlace(next).int() })).found_existing) continue;
                    } else {
                        if (!it.free) {
                            if (e.step.kind == .level) {
                                it.free = true;
                            } else if (!it.stuck) {
                                if (try shapes.proj(gpa, f.account(), places, env.cells, it.value, e.step)) |n| it.value = n else it.stuck = true;
                            }
                            if (!it.free and (try x.exact_seen.getOrPut(gpa, .{ e.parent, it.node.int(), it.value.int(), @intFromBool(it.stuck) })).found_existing) continue;
                        }
                        it.path = if (it.free or it.path == .none) .none else (try places.extend(gpa, env.charge, it.path, e.step)) orelse .none;
                    }
                }
                if (!it.merged and x.merge and !it.free and !it.stuck and it.path != .none and !places.isSummary(it.path) and
                    places.isPrefix(.from(lc.b), it.path) and (try x.plain.bits(env, &x.plain_memo, &x.below, it.node, it.path)) & 1 != 0)
                {
                    // Merged from here: every route below is plain.
                    it.merged = true;
                    it.sig = try x.plain.sigOf(env, it.path);
                    var t = it.path;
                    var child: PathId = .none;
                    while (!inTrie(x, lc.a, lc.c, t)) {
                        child = t;
                        t = places.pathParent(t);
                    }
                    it.t = t;
                    it.class = if (child == .none) 0 else 1 + places.pathPlace(child).int();
                    if ((try x.seen.getOrPut(gpa, .{ it.node.int(), it.t.int(), it.class, it.sig, places.pathPlace(it.path).int() })).found_existing) continue;
                }
                var wr = false;
                var deep = false;
                var ct = env.cells.sets.iterate(try shapes.cellsOf(gpa, f.account(), &env.cells.sets, it.node));
                while (ct.next()) |c| {
                    const cell: CellId = .from(c.key);
                    if (env.cells.origin(cell) != .mark) continue;
                    switch (env.cells.markOf(cell)) {
                        .w => wr = true,
                        .deep => deep = true,
                        else => {},
                    }
                }
                if (shapes.kind(it.node) == .node) {
                    var kt = shapes.overEntries(shapes.get(it.node).a);
                    while (kt.next()) |k| {
                        if ((x.below.get(.{k.node.int()}) orelse 3) & 1 == 0) continue;
                        const id: u32 = @intCast(x.entries.items.len);
                        try x.entries.append(gpa, .{ .step = k.step, .parent = it.entry });
                        var next = it;
                        next.node = k.node;
                        next.entry = id;
                        try x.stack.append(gpa, next);
                    }
                }
                if (!wr) continue;
                x.steps.clearRetainingCapacity();
                try x.steps.appendSlice(gpa, f.group_steps.items[g.prefix.start..][0..g.prefix.len]);
                const mark = x.steps.items.len;
                var at = it.entry;
                while (at != none) : (at = x.entries.items[at].parent) try x.steps.append(gpa, x.entries.items[at].step);
                std.mem.reverse(Step, x.steps.items[mark..]);
                try f.groupDemand(x, g, x.steps.items, deep, beside);
            }
        }

        /// One demand of a group, at the call, as the call makes one per route
        /// (`call`): its base the argument at `ws`, the call's other arguments
        /// and the argument's other paths its operands.
        pub fn groupDemand(f: *Frame, x: *Expand, g: *const Group, ws: []const Step, deep: bool, beside: *Beside) Error!void {
            const s = f.call_snaps.items[g.call];
            const arg_insts = f.snapArgs(g.call);
            const arg = arg_insts[g.param].int();
            const argv = f.val(arg).value;
            const base_walk = try f.account().enter(f.gpa, null);
            const pos = try f.positionsAt(argv, ws);
            f.account().leave(base_walk);
            const base = pos orelse return;
            x.others.clearRetainingCapacity();
            for (arg_insts, 0..) |a, k| if (k != g.param) try x.others.append(f.gpa, a.int());
            try f.demand(s.point, if (deep) .consumed else .writer, arg, base, x.others.items, s.callee_inst);
            try f.otherPaths(beside, g.use, argv, ws, base, arg, deep);
            if (ws.len != 0) {
                const dm = &f.demands.items[f.demands.items.len - 1];
                const path_walk = try f.account().enter(f.gpa, null);
                defer f.account().leave(path_walk);
                dm.write_path = try f.extendPath(try f.env.places.rootPath(f.gpa, try f.placeOf(arg)), ws);
                if (dm.base_path != .none) dm.base_path = try f.extendPath(dm.base_path, ws);
            }
        }
    };
}
