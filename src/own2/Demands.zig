//! L6: demands and the check (`docs/design/ownership-v2.md` §2.8). A demand
//! is a write the walk met — a writer call, a construction, a `++` chain, a
//! deep consumption — at a point, on a base value; this file resolves each
//! one, in evaluation order, against six conditions in R-4.3.6's order:
//!
//! 1. **Known**: no `⊤` among the base's cells (`unknown`).
//! 2. **Unescaped**: no cell, nor a trie ancestor of it (nor, for a deep
//!    demand, a descendant), escaped at a compatible point before; no
//!    `shared` cell (`top-level`).
//! 3. **Not captured**: S4's (closures).
//! 4. **Disjoint**: no other operand reaches a cell of the base.
//! 5. **Dead**: no pending operand holds it (`held-operand`); no live holder
//!    is used after the point, compatibly, at an overlapping path
//!    (`later-use` the base's own variable, `alias` another, `element` when
//!    the holder holds it only at a summary position).
//! 6. **Exclusive**: what passed only *under* a split rests on the split's
//!    κ: `yes` passes, atoms are the frame's `xreq`, a failure is
//!    `exclusive`.
//!
//! **Holders come from a live inverted index, never a scan of the scope.**
//! A holder — a binding, a pending computed operand — registers on the root
//! of its value's persistent `reach` set (`Cell.Radix`). A set node is live
//! while something live refers to it: a holder rooted at it or a live
//! parent; a node going live links itself under its children, so a cell's
//! holders are found from its leaf node by climbing live parent links to
//! the roots. Hash-consed sets share subtrees, so a result whose `reach`
//! shares its operand's nodes keeps them live across the hand-over (§2.8:
//! the holder expires AFTER the point's own result is registered).
//!
//! **Holders across a cycle** (§2.8): a leaf going live also links its
//! symbolic cell into one chain per *cycle anchor* of its canonical path —
//! a prefix whose place lies on a cyclic SCC and whose next step stays on it
//! — keyed by `(origin, index, j, anchor path, ⟲ or on-cycle)`. A demand on
//! a cell whose path continues an anchor with `⟲` reads the anchor's
//! on-cycle chain (a holder of the children list holds every level below);
//! a deep demand continuing it with an on-cycle step reads its `⟲` chain.
//! `Cell.alias` decides each candidate, `Cell.below` keeps a shallow
//! storage write from counting against the elements a holder holds.
//!
//! Every record — a live-count transition, a link, a candidate inspected,
//! a query — is reserved on the owner's account before its work (§4.1).
//!
//! Obligations kept here: O8's demand half (a write is blocked by an
//! escaped ancestor-or-self, a deep demand also by a descendant), O12's
//! (a holder's later use is this frame's own use the index recorded), and
//! I-κ's use (an answer that rests on a split relies on its κ).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Liveness = @import("Liveness.zig");
const Regions = @import("Regions.zig");
const stamped = @import("../stamped.zig");

pub const NodeId = Ids.NodeId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const PathId = Ids.PathId;
pub const CondId = Ids.CondId;
pub const UseId = Ids.UseId;
pub const Kappas = Cond.Kappas;
pub const Env = Summary.Env;
pub const Error = Ids.ChargeError;
pub const Step = Shape.Step;
pub const none: u32 = Ids.none_int;

/// A value interpretation (§2.9): its shape root and its own κ snapshot.
pub const Value = struct {
    node: NodeId = .none,
    kappa: Kappas = .none,
};

/// One demand the walk met (§2.8).
pub const Demand = struct {
    point: u32,
    kind: Facts.DemandKind,
    base: Value,
    /// The instruction the base was read from, for its text.
    base_inst: u32,
    /// The local the base reads, at `base_path`, or `none` for a computed
    /// base: what tells `later-use` from `alias`.
    base_local: u32 = none,
    base_path: PathId = .none,
    /// The main token of the demand's instruction: its position.
    token: u32,
    /// A writer call's callee instruction, for its name; `none` otherwise.
    callee_inst: u32 = none,
    /// A writer call's write path below the base, and its callee's `xreq` (§2.11).
    write_path: PathId = .none,
    relies: CondId = Cond.yes,
    /// The other operands of the operation, a run of `Frame.operands`.
    operands: Ids.Range = .empty,
};

pub const Operand = struct { value: Value, inst: u32 };

pub const HolderKind = enum(u8) { binding, pending };

/// A holder (§2.8): a binding of a local, live from its binding to its last
/// use, or a computed value evaluated before its consumer, live in between.
pub const Holder = struct {
    kind: HolderKind,
    /// `binding`: the local; `pending`: the instruction.
    who: u32,
    value: Value,
    start: u32,
    end: u32,
    /// `binding`: the local's root path (its place's `ε`), what the use
    /// index keys its uses under.
    root: PathId,
    token: u32,
    /// `binding` of a list pattern's position (§2.13.3): which.
    taken: Taken = .{},
};

/// A pattern variable bound at position `pos` of split `split`, with the
/// explicit cells at the container's `[*]` (a concrete container's
/// elements) that every position holds: two positions of one split hold
/// one of them only if the split's κ fails, as `elem`s of two sides do.
pub const Taken = struct { split: Ids.SplitId = .none, pos: u32 = none, explicit: SetId = .none };

pub const Escape = struct { node: NodeId, point: u32 };

pub const Frame = struct {
    demands: []const Demand,
    operands: []const Operand,
    holders: []const Holder,
    escapes: []const Escape,
    index: *const Liveness.Index,
    regions: *const Regions.Tree,
    /// Per local, its binding's index in `holders`, or `none`.
    bindings: []const u32 = &.{},
};

/// A resolved demand: its verdict and what the message names.
pub const Outcome = struct {
    verdict: Kind,
    accepted: Facts.Verdict.Accepted = .fresh,
    cause: Facts.Cause = .unknown,
    exactness: Facts.Exactness = .exact,
    /// The holder named: a `Holder` index, or `none`.
    holder: u32 = none,
    /// Where the holder holds it, a path under its local's root.
    holder_path: PathId = .none,
    /// The holder's later use.
    use: UseId = .none,
    /// `top_level`: the shared cell; `escaped`: the point it escaped at.
    cell: CellId = .none,
    /// The atoms the acceptance relies on (a set in `Cond.atoms`).
    xreq: SetId = .none,

    pub const Kind = enum(u8) { accepted, refused };
};

// ---------------------------------------------------------------------------
// The live inverted index (§2.8)
// ---------------------------------------------------------------------------

/// A step's slot (§4.4 *holder and callee path words*): the demanded value's
/// own path, or the path a holder holds it at.
const StepSlot = enum(u1) { base, holder };

/// The kernel of demand `atom`'s step `path` (§2.8, §4.4's `(written demand,
/// slot, k)` words on direct-demand-query lanes, `k` the step's depth): the
/// prefix work at one step of a path (its escape, its candidates and anchors,
/// its refinement chain, a use query at it) is that step's, never the demand's
/// whole lane (#1225). Null at a root path, outside a demand's query, or when
/// the query is already growth (a product, a sweep past the direct holder):
/// there the step's work is the growth task's, never piled onto one lane per
/// step (#1233's review).
fn stepLane(env: Env, gpa: Allocator, atom: ?u32, slot: StepSlot, path: PathId) Error!?Ids.Account.Kernel {
    const a = atom orelse return null;
    if (path == .none or env.places.pathParent(path) == .none) return null;
    if (env.account().inGrowth()) return null;
    return try env.account().enter(gpa, .{ .atom = a, .role = .direct_demand_query, .step = stepWord(slot, env.places.pathDepth(path)) });
}

/// A step lane's word: its slot and its depth `k` (§4.4).
fn stepWord(slot: StepSlot, depth: u32) u32 {
    return (@as(u32, @backingInt(slot)) << 28) | depth;
}

/// `stepLane` of a cell's canonical path, for a symbolic cell; null for any
/// other, whose work stays the demand's.
fn cellLane(env: Env, gpa: Allocator, atom: ?u32, c: CellId) Error!?Ids.Account.Kernel {
    const x = env.cells.get(c);
    if (!x.origin.isSymbolic() or x.origin == .top) return null;
    return stepLane(env, gpa, atom, .base, .from(x.b));
}

fn leaveLane(env: Env, k: ?Ids.Account.Kernel) void {
    if (k) |kk| env.account().leave(kk);
}

const Live = struct {
    gpa: Allocator,
    env: Env,
    /// Per set node: its live references (holders rooted at it, live parents).
    count: std.ArrayList(u32) = .empty,
    /// Per set node: the head of its live-parent list, a link id
    /// (`parent · 2 + side`), and per link id its neighbours.
    phead: std.ArrayList(u32) = .empty,
    lnext: std.ArrayList(u32) = .empty,
    lprev: std.ArrayList(u32) = .empty,
    /// Per set node: the head of the list of holders rooted at it; per
    /// holder its neighbours.
    rhead: std.ArrayList(u32) = .empty,
    hnext: []u32 = &.{},
    hprev: []u32 = &.{},
    /// The anchor chains: `(origin·kind, index, anchor path, class·j)` → the
    /// head of a list of live leaves, `alink` the links (per leaf node).
    anchors: Ids.FixedDict(4) = .{},
    anchor_links: std.ArrayList(AnchorLink) = .empty,
    /// Per leaf node: its first anchor link, `none` when unlinked.
    leaf_anchor: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(SetId) = .empty,
    /// The refinement chains (§2.8) are kept per split: a member chain per
    /// `(path, split)` in `anchors`, and per path a list of its non-empty
    /// splits' groups, so a demand reads one member of its own split's
    /// siblings, not each (they all answer `under` that split).
    groups: std.ArrayList(Group) = .empty,
    group_of: Ids.FixedDict(1) = .{},
    group_heads: Ids.FixedDict(4) = .{},

    const AnchorLink = struct { leaf: SetId, chain: u32, next: u32, prev: u32, next_of_leaf: u32 };
    const Group = struct { members: u32, split: Ids.SplitId, path: u32, next: u32, prev: u32 };

    fn deinit(l: *Live) void {
        const gpa = l.gpa;
        l.count.deinit(gpa);
        l.phead.deinit(gpa);
        l.lnext.deinit(gpa);
        l.lprev.deinit(gpa);
        l.rhead.deinit(gpa);
        gpa.free(l.hnext);
        gpa.free(l.hprev);
        l.anchors.deinit(gpa);
        l.groups.deinit(gpa);
        l.group_of.deinit(gpa);
        l.group_heads.deinit(gpa);
        l.anchor_links.deinit(gpa);
        l.leaf_anchor.deinit(gpa);
        l.stack.deinit(gpa);
    }

    /// The columns grown to the set table as it is now.
    fn grow(l: *Live) Allocator.Error!void {
        const n = l.env.cells.sets.nodeCount();
        const gpa = l.gpa;
        while (l.count.items.len < n) {
            try l.count.append(gpa, 0);
            try l.phead.append(gpa, none);
            try l.rhead.append(gpa, none);
            try l.leaf_anchor.append(gpa, none);
            try l.lnext.appendSlice(gpa, &.{ none, none });
            try l.lprev.appendSlice(gpa, &.{ none, none });
        }
    }

    fn linkParent(l: *Live, child: SetId, link: u32) void {
        const c = child.int();
        l.lnext.items[link] = l.phead.items[c];
        l.lprev.items[link] = none;
        if (l.phead.items[c] != none) l.lprev.items[l.phead.items[c]] = link;
        l.phead.items[c] = link;
    }

    fn unlinkParent(l: *Live, child: SetId, link: u32) void {
        const c = child.int();
        const p = l.lprev.items[link];
        const n = l.lnext.items[link];
        if (p != none) l.lnext.items[p] = n else l.phead.items[c] = n;
        if (n != none) l.lprev.items[n] = p;
    }

    /// One more live reference to `root`; nodes that go live link under
    /// their children, every transition one record.
    fn ref(l: *Live, root: SetId) Error!void {
        try l.grow();
        l.stack.clearRetainingCapacity();
        try l.env.charge.reserve(l.gpa, .inspection, 1);
        l.count.items[root.int()] += 1;
        if (l.count.items[root.int()] == 1) try l.stack.append(l.gpa, root);
        while (l.stack.pop()) |n| {
            const kids = l.env.cells.sets.branches(n) orelse {
                try l.linkAnchors(n);
                continue;
            };
            for (kids, 0..) |k, side| {
                try l.env.charge.reserve(l.gpa, .inspection, 1);
                l.linkParent(k, n.int() * 2 + @as(u32, @intCast(side)));
                l.count.items[k.int()] += 1;
                if (l.count.items[k.int()] == 1) try l.stack.append(l.gpa, k);
            }
        }
    }

    fn deref(l: *Live, root: SetId) Error!void {
        l.stack.clearRetainingCapacity();
        try l.env.charge.reserve(l.gpa, .inspection, 1);
        l.count.items[root.int()] -= 1;
        if (l.count.items[root.int()] == 0) try l.stack.append(l.gpa, root);
        while (l.stack.pop()) |n| {
            const kids = l.env.cells.sets.branches(n) orelse {
                l.unlinkAnchors(n);
                continue;
            };
            for (kids, 0..) |k, side| {
                try l.env.charge.reserve(l.gpa, .inspection, 1);
                l.unlinkParent(k, n.int() * 2 + @as(u32, @intCast(side)));
                l.count.items[k.int()] -= 1;
                if (l.count.items[k.int()] == 0) try l.stack.append(l.gpa, k);
            }
        }
    }

    fn register(l: *Live, h: u32, root: SetId) Error!void {
        try l.ref(root);
        const r = root.int();
        l.hnext[h] = l.rhead.items[r];
        l.hprev[h] = none;
        if (l.rhead.items[r] != none) l.hprev[l.rhead.items[r]] = h;
        l.rhead.items[r] = h;
    }

    fn expire(l: *Live, h: u32, root: SetId) Error!void {
        const r = root.int();
        const p = l.hprev[h];
        const n = l.hnext[h];
        if (p != none) l.hnext[p] = n else l.rhead.items[r] = n;
        if (n != none) l.hprev[n] = p;
        try l.deref(root);
    }

    /// The cell a leaf holds.
    fn leafCell(l: *Live, leaf: SetId) CellId {
        var it = l.env.cells.sets.iterate(leaf);
        return .from(it.next().?.key);
    }

    /// The anchor keys of a symbolic cell's canonical path (§2.8): every
    /// prefix on a cyclic SCC whose next step stays on it. A refinement
    /// anchors by its canonical position.
    /// `atom`: the demand whose query reads them, each step on its lane
    /// (#1225); null when a holder registers.
    fn anchorsOf(l: *Live, c: CellId, out: *std.ArrayList([4]u32), atom: ?u32) Error!void {
        const sym = (try l.env.cells.unrefined(l.gpa, l.env.account(), l.env.places, c)) orelse return;
        const x = l.env.cells.get(sym);
        if (!x.origin.isSymbolic() or x.origin == .top) return;
        const places = l.env.places;
        // Only the anchor prefixes, nearest first (`Place.anchorUp`, #1236): a
        // step off every cycle names no anchor, so it is never visited.
        var at: PathId = places.anchorUp(.from(x.b));
        while (at != .none and places.pathParent(at) != .none) : (at = places.anchorUp(places.pathParent(at))) {
            const lane = try stepLane(l.env, l.gpa, atom, .base, at);
            defer leaveLane(l.env, lane);
            try l.env.charge.reserve(l.gpa, .inspection, 1);
            const parent = places.pathParent(at);
            const step = places.pathStep(at);
            // `⟲` re-enters its place, which is on a cycle by that alone.
            const on_level = step.kind == .level;
            const class: u32 = if (on_level) 1 else 0;
            try out.append(l.gpa, .{ (@as(u32, @backingInt(x.origin)) << 8) | 1, x.a, parent.int(), (x.c << 1) | class });
        }
    }

    /// The refinement chain of a refinement (§2.8): its canonical path's
    /// key, with its split (`(container, label)`) as the last word, and
    /// the path's group-list key; null for a refinement of a concrete cell
    /// (its contents are explicit children).
    fn refinementKey(l: *Live, c: CellId) Error!?struct { members: [4]u32, path: [4]u32, split: Ids.SplitId } {
        const cells = l.env.cells;
        if (!cells.origin(c).isRefinement()) return null;
        const sym = (try cells.unrefined(l.gpa, l.env.account(), l.env.places, c)) orelse return null;
        const x = cells.get(c);
        const split = cells.findSplit(x.parent, .from(x.b));
        const path = l.pathKey(sym, .from(cells.get(sym).b));
        const tag = (path[0] & ~@as(u32, 0xff)) | 2;
        return .{ .members = .{ tag, path[1], path[2], split.int() }, .path = path, .split = split };
    }

    /// The group-list key of symbolic cell `sym`'s origin at `path`.
    fn pathKey(l: *Live, sym: CellId, path: PathId) [4]u32 {
        const x = l.env.cells.get(sym);
        std.debug.assert(x.c < 1 << 16);
        return .{ (@as(u32, @backingInt(x.origin)) << 8) | 3 | (x.c << 16), x.a, path.int(), 0 };
    }

    fn linkAnchors(l: *Live, leaf: SetId) Error!void {
        var keys: std.ArrayList([4]u32) = .empty;
        defer keys.deinit(l.gpa);
        const cell = l.leafCell(leaf);
        try l.anchorsOf(cell, &keys, null);
        // A refinement is also in the chain of its canonical path and split.
        const rk = try l.refinementKey(cell);
        if (rk) |k| try keys.append(l.gpa, k.members);
        for (keys.items, 0..) |key, i| {
            try l.env.charge.reserve(l.gpa, .edge, 1);
            const got = try l.anchors.getOrPut(l.gpa, key);
            if (!got.found_existing) got.value_ptr.* = none;
            const was_empty = got.value_ptr.* == none;
            const chain = got.index;
            const id: u32 = @intCast(l.anchor_links.items.len);
            try l.anchor_links.append(l.gpa, .{ .leaf = leaf, .chain = chain, .next = got.value_ptr.*, .prev = none, .next_of_leaf = l.leaf_anchor.items[leaf.int()] });
            if (got.value_ptr.* != none) l.anchor_links.items[got.value_ptr.*].prev = id;
            got.value_ptr.* = id;
            l.leaf_anchor.items[leaf.int()] = id;
            // A split's chain at a path going live joins the path's list.
            if (rk != null and i == keys.items.len - 1 and was_empty) try l.linkGroup(chain, rk.?.path, rk.?.split);
        }
    }

    fn linkGroup(l: *Live, chain: u32, path: [4]u32, split: Ids.SplitId) Error!void {
        try l.env.charge.reserve(l.gpa, .edge, 1);
        const g = try l.group_of.getOrPut(l.gpa, .{chain});
        if (!g.found_existing) {
            g.value_ptr.* = @intCast(l.groups.items.len);
            try l.groups.append(l.gpa, .{ .members = chain, .split = split, .path = none, .next = none, .prev = none });
        }
        const id = g.value_ptr.*;
        const h = try l.group_heads.getOrPut(l.gpa, path);
        if (!h.found_existing) h.value_ptr.* = none;
        l.groups.items[id].path = h.index;
        l.groups.items[id].next = h.value_ptr.*;
        l.groups.items[id].prev = none;
        if (h.value_ptr.* != none) l.groups.items[h.value_ptr.*].prev = id;
        h.value_ptr.* = id;
    }

    fn unlinkAnchors(l: *Live, leaf: SetId) void {
        var at = l.leaf_anchor.items[leaf.int()];
        while (at != none) {
            const a = l.anchor_links.items[at];
            if (a.prev != none) l.anchor_links.items[a.prev].next = a.next else l.anchors.values.items[a.chain] = a.next;
            if (a.next != none) l.anchor_links.items[a.next].prev = a.prev;
            // A split's chain going empty leaves its path's list.
            if (l.anchors.values.items[a.chain] == none) if (l.group_of.get(.{a.chain})) |g| {
                const x = l.groups.items[g];
                if (x.prev != none) l.groups.items[x.prev].next = x.next else l.group_heads.values.items[x.path] = x.next;
                if (x.next != none) l.groups.items[x.next].prev = x.prev;
            };
            at = a.next_of_leaf;
        }
        l.leaf_anchor.items[leaf.int()] = none;
    }
};

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

const Resolver = struct {
    gpa: Allocator,
    env: Env,
    frame: Frame,
    live: Live,
    /// Escapes: per cell, a run of points (`esc_points`).
    esc: stamped.Column(CellId, Ids.Range) = .{},
    esc_points: std.ArrayList(u32) = .empty,
    /// Per point of a run, the run prefix's point of least rank₂.
    esc_low: std.ArrayList(u32) = .empty,
    visited: stamped.Column(SetId, void) = .{},
    seen_holder: stamped.Column(CellId, void) = .{},
    /// The query's growth task once its sweep passed the one direct holder
    /// at one path its lane has (§4.1's *direct demand query*, #1201): left
    /// when the query ends.
    spill: ?Ids.Account.Kernel = null,
    /// Set inside a step's lane (`chain`), where `spill` cannot be entered:
    /// the sweep enters it once back at its own level.
    want_spill: bool = false,
    /// The demand being resolved's atom (its base's instruction), whose step
    /// lanes its path work goes on (`stepLane`, #1225).
    atom: ?u32 = null,
    steps: std.ArrayList(Step) = .empty,
    /// Per holder: whether it is registered.
    on: []bool = &.{},

    fn deinit(r: *Resolver) void {
        r.live.deinit();
        r.esc.deinit(r.gpa);
        r.esc_points.deinit(r.gpa);
        r.esc_low.deinit(r.gpa);
        r.visited.deinit(r.gpa);
        r.seen_holder.deinit(r.gpa);
        r.steps.deinit(r.gpa);
        r.gpa.free(r.on);
    }

    fn reach(r: *Resolver, n: NodeId) Error!SetId {
        return r.env.shapes.reach(r.gpa, r.env.account(), &r.env.cells.sets, n);
    }

    /// Whether `c` (or, for a deep demand, what it holds) could have reached a
    /// holder whose value is `n`: some cell of `n`'s reach other than `⊤`
    /// conflicts with it. What a value got from an opaque result or a
    /// pessimistic call is in its reach as its arrivals (`⋆ ~π1`), so a `⊤`
    /// holder that never took `c` does not hold it. A record per cell read.
    fn mayHaveReached(r: *Resolver, n: NodeId, c: CellId, deep: bool, cands: []const CellId) Error!bool {
        const cellt = r.env.cells;
        const held = try r.reach(n);
        // The candidates for `c` (itself, its trie ancestors, its named
        // descendants for a deep demand, its anchors' cells): one lookup each,
        // never a walk of the holder's reach.
        for (cands) |x| {
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            if (cellt.origin(x) == .top or !cellt.sets.member(held, x.int())) continue;
            if (r.conflict(x, c, deep) != .no) return true;
        }
        return false;
    }

    /// A holder's registration and expiry kernel (§4.1's holder index): its
    /// local's lane, or its instruction's for a pending operand, when its
    /// value holds at most `holder_kernel_cells` cells (a one-key update of
    /// the index per cell); a wider value's is a general task, growth until
    /// the index is updated per written atom (#1098). Chosen before the
    /// work, on a bounded count charged to the lane.
    fn holderLane(r: *Resolver, h: Holder, root: SetId) Error!?Ids.Lane {
        const atom = if (h.kind == .binding) Ids.atom_local_bit | h.who else h.who;
        const lane: Ids.Lane = .{ .atom = atom, .role = .holder_index };
        const kernel = try r.env.account().enter(r.gpa, lane);
        defer r.env.account().leave(kernel);
        var it = r.env.cells.sets.iterate(root);
        var n: u32 = 0;
        while (it.next()) |_| {
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            n += 1;
            if (n > holder_kernel_cells) return null;
        }
        return lane;
    }

    const holder_kernel_cells = 32;

    fn compatible(r: *Resolver, a: u32, b: u32) bool {
        return r.frame.regions.compatible(a, b);
    }

    /// Every cell of every escaped value, with the point it escaped at:
    /// escape is deep, so `reach` (§2.4).
    fn buildEscapes(r: *Resolver) Error!void {
        // Every (cell, point) as one word, sorted: each cell's points are one
        // run in point order, beside each the run prefix's point of least
        // rank₂ (`esc_low`), so `escapedAt` is one binary search (#1226).
        var pairs: std.ArrayList(u64) = .empty;
        defer pairs.deinit(r.gpa);
        for (r.frame.escapes) |e| {
            var it = r.env.cells.sets.iterate(try r.reach(e.node));
            while (it.next()) |x| {
                try r.env.charge.reserve(r.gpa, .inspection, 1);
                try pairs.append(r.gpa, @as(u64, x.key) << 32 | e.point);
            }
        }
        try r.env.charge.reserve(r.gpa, .inspection, @intCast(pairs.items.len * (std.math.log2_int_ceil(usize, pairs.items.len + 1) + 1)));
        std.mem.sort(u64, pairs.items, {}, std.sort.asc(u64));
        try r.esc_points.resize(r.gpa, pairs.items.len);
        try r.esc_low.resize(r.gpa, pairs.items.len);
        for (pairs.items, 0..) |q, i| {
            const pt: u32 = @truncate(q);
            const got = try r.esc.getOrPut(r.gpa, .from(@intCast(q >> 32)));
            if (!got.found_existing) got.value_ptr.* = .{ .start = @intCast(i), .len = 0 };
            got.value_ptr.len += 1;
            r.esc_points.items[i] = pt;
            const low = if (got.value_ptr.len == 1) pt else r.esc_low.items[i - 1];
            r.esc_low.items[i] = if (r.frame.regions.rank2(pt) < r.frame.regions.rank2(low)) pt else low;
        }
    }

    /// The point `c` escaped at before `p`, compatibly, or null. For e < p,
    /// compatible ⇔ rank₂(e) < rank₂(p) (§2.5): the least rank₂ before `p`
    /// decides, by a binary search charged as growth (#1226), never a scan.
    fn escapedAt(r: *Resolver, c: CellId, p: u32) Error!?u32 {
        const run = r.esc.get(c) orelse return null;
        // One point is one test, which the caller's step already paid for;
        // a longer run's search is as large as the run, so growth chosen
        // before it, never the demand's fixed lane (§4.1).
        const task: ?Ids.Account.Kernel = if (run.len > 1) try r.env.account().enter(r.gpa, null) else null;
        defer if (task) |k| r.env.account().leave(k);
        if (task != null) try r.env.charge.reserve(r.gpa, .inspection, std.math.log2_int_ceil(u32, run.len + 1) + 1);
        const before = std.sort.partitionPoint(u32, r.esc_points.items[run.start..][0..run.len], p, struct {
            fn below(bound: u32, e: u32) bool {
                return e < bound;
            }
        }.below);
        if (before == 0) return null;
        const e = r.esc_low.items[run.start + before - 1];
        return if (r.frame.regions.rank2(e) < r.frame.regions.rank2(p)) e else null;
    }

    /// Escaped itself or through a trie ancestor; for a deep demand, a
    /// named descendant too (§2.4, O8).
    fn escaped(r: *Resolver, c: CellId, p: u32, deep: bool) Error!?u32 {
        var at = c;
        while (at != .none) : (at = r.env.cells.parent(at)) {
            const lane = try cellLane(r.env, r.gpa, r.atom, at);
            defer leaveLane(r.env, lane);
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            if (try r.escapedAt(at, p)) |e| return e;
        }
        if (!deep) return null;
        return r.escapedBelow(c, p);
    }

    fn escapedBelow(r: *Resolver, c: CellId, p: u32) Error!?u32 {
        // Every cell below the base: as many as the value has, a walk in
        // growth, never the demand's lane (#1201).
        const walk = try r.env.account().enter(r.gpa, null);
        defer r.env.account().leave(walk);
        var stack: std.ArrayList(CellId) = .empty;
        defer stack.deinit(r.gpa);
        try stack.append(r.gpa, c);
        while (stack.pop()) |x| {
            var it = r.env.cells.children(x);
            while (it.next()) |k| {
                try r.env.charge.reserve(r.gpa, .inspection, 1);
                if (try r.escapedAt(k, p)) |e| return e;
                try stack.append(r.gpa, k);
            }
        }
        return null;
    }

    /// Whether `d` may be the object `c` (or contain it, for a deep demand),
    /// and how (§2.2 `alias`; §2.8: a shallow storage write never counts
    /// against the elements a holder holds).
    fn conflict(r: *Resolver, d: CellId, c: CellId, deep: bool) Cell.Alias {
        if (!deep and r.env.cells.below(r.env.places, d, c)) return .no;
        return r.env.cells.alias(r.env.places, d, c);
    }

    /// The candidates for `c`'s holders (§2.8): itself, its trie ancestors,
    /// its named descendants for a deep demand, the live cells its cycle
    /// anchors name.
    fn candidates(r: *Resolver, c: CellId, deep: bool, out: *std.ArrayList(CellId)) Error!void {
        // `⊤` may be any object: a live holder of it (a value an opaque
        // result or a pessimistic call kept) may hold `c` (§2.2: `⊤`
        // aliases everything).
        try out.append(r.gpa, try r.env.cells.top(r.gpa, r.env.account()));
        var at = c;
        while (at != .none) : (at = r.env.cells.parent(at)) {
            const lane = try cellLane(r.env, r.gpa, r.atom, at);
            defer leaveLane(r.env, lane);
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            try out.append(r.gpa, at);
        }
        // A refinement's canonical cell (`elem(c·ι)` is `c[*]`) and its trie
        // ancestors: what a holder that never took the split names (a
        // container's explicit `[*]` child holding `c[*]`). Then the
        // refinement chain at the canonical path and at each ancestor of it:
        // the live refinements another split or another position of this
        // one took there (a sibling, a view's `others`), §2.8.
        const unrefined = try r.env.cells.unrefined(r.gpa, r.env.account(), r.env.places, c);
        if (unrefined) |u| {
            if (u != c) {
                at = u;
                while (at != .none) : (at = r.env.cells.parent(at)) {
                    const lane = try cellLane(r.env, r.gpa, r.atom, at);
                    defer leaveLane(r.env, lane);
                    try r.env.charge.reserve(r.gpa, .inspection, 1);
                    try out.append(r.gpa, at);
                }
            }
            var path: PathId = .from(r.env.cells.get(u).b);
            while (path != .none) : (path = r.env.places.pathParent(path)) {
                const lane = try stepLane(r.env, r.gpa, r.atom, .base, path);
                defer leaveLane(r.env, lane);
                try r.chain(u, path, c, out);
            }
        }
        // And at the canonical path of each refinement `c` lies in (§2.8: "at
        // c's canonical path and at each of its trie ancestors"): a view's
        // `others(k·ι)` holds the elements of `k` that a later position of
        // the view took, so it CONTAINS what lies under that position, even
        // when `⟲` folds both to one path. Upwards only: a holder below `c`
        // is `conflict`'s to drop for a shallow demand.
        at = r.env.cells.parent(c);
        while (at != .none and r.env.cells.origin(at).isRefinement()) : (at = r.env.cells.parent(at)) {
            const lane = try cellLane(r.env, r.gpa, r.atom, at);
            defer leaveLane(r.env, lane);
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            const ua = (try r.env.cells.unrefined(r.gpa, r.env.account(), r.env.places, at)) orelse continue;
            try r.chain(ua, .from(r.env.cells.get(ua).b), at, out);
        }
        if (deep) {
            var stack: std.ArrayList(CellId) = .empty;
            defer stack.deinit(r.gpa);
            try stack.append(r.gpa, c);
            if (unrefined) |u| if (u != c) try stack.append(r.gpa, u);
            while (stack.pop()) |x| {
                var it = r.env.cells.children(x);
                while (it.next()) |k| {
                    try r.env.charge.reserve(r.gpa, .inspection, 1);
                    try out.append(r.gpa, k);
                    try stack.append(r.gpa, k);
                }
            }
        }
        // Anchors: for each anchor of `c` with next step `⟲`, the live cells
        // of its on-cycle chain; with an on-cycle step and a deep demand,
        // its `⟲` chain.
        var keys: std.ArrayList([4]u32) = .empty;
        defer keys.deinit(r.gpa);
        try r.live.anchorsOf(c, &keys, r.atom);
        for (keys.items) |key| {
            const class = key[3] & 1;
            if (class == 0 and !deep) continue;
            var other = key;
            other[3] = (key[3] & ~@as(u32, 1)) | (1 - class);
            const head = r.live.anchors.get(other) orelse continue;
            var link = head;
            while (link != none) {
                try r.env.charge.reserve(r.gpa, .inspection, 1);
                const a = r.live.anchor_links.items[link];
                try out.append(r.gpa, r.live.leafCell(a.leaf));
                link = a.next;
            }
        }
    }

    /// The live refinements at `sym`'s origin and `path` (§2.8), split by
    /// split: of `own`'s split (`self`'s siblings and its view's `others`,
    /// each answering `under` that one split) one member, never `self`;
    /// of any other split, every member. O(splits at the path + members of
    /// the other splits), not the number of siblings.
    fn chain(r: *Resolver, sym: CellId, path: PathId, self: CellId, out: *std.ArrayList(CellId)) Error!void {
        const cells = r.env.cells;
        const own: Ids.SplitId = if (cells.origin(self).isRefinement()) cells.findSplit(cells.parent(self), .from(cells.get(self).b)) else .none;
        try r.env.charge.reserve(r.gpa, .inspection, 1);
        var g = r.live.group_heads.get(r.live.pathKey(sym, path)) orelse return;
        // Past the first member the live refinements here are a sweep: growth
        // for the rest of this chain, and for the query once back at the
        // sweep's level (`want_spill`, #1201). `chain` runs on a step's lane,
        // so its growth is scoped to it.
        var members: u32 = 0;
        var past: ?Ids.Account.Kernel = null;
        defer leaveLane(r.env, past);
        while (g != none) : (g = r.live.groups.items[g].next) {
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            const group = r.live.groups.items[g];
            const one = own != .none and group.split == own;
            var link = r.live.anchors.values.items[group.members];
            while (link != none) {
                try r.env.charge.reserve(r.gpa, .inspection, 1);
                const a = r.live.anchor_links.items[link];
                link = a.next;
                const d = r.live.leafCell(a.leaf);
                if (one and d == self) continue;
                if (members == 1 and past == null) {
                    past = try r.env.account().enter(r.gpa, null);
                    r.want_spill = true;
                }
                members += 1;
                try out.append(r.gpa, d);
                if (one) break;
            }
        }
    }

    /// From here on the query's sweep is growth, chosen before the next
    /// holder's, radix node's or hold path's share: its lane has one direct
    /// holder at one path (§4.1's *direct demand query*); enumerating more is
    /// not that kernel (#1201).
    fn spillNow(r: *Resolver) Error!void {
        if (r.spill == null) r.spill = try r.env.account().enter(r.gpa, null);
    }

    /// The registered holders whose `reach` holds `d`: climb from `d`'s
    /// live leaves through live parents to the roots, every node once.
    fn holdersOf(r: *Resolver, d: CellId, out: *std.ArrayList(u32)) Error!void {
        r.visited.clear();
        var stack: std.ArrayList(SetId) = .empty;
        defer stack.deinit(r.gpa);
        try r.live.grow();
        for ([_]u1{ 0, 1 }) |v| {
            const leaf = r.env.cells.sets.leafOf(d.int(), v) orelse continue;
            if (r.live.count.items[leaf.int()] == 0) continue;
            try stack.append(r.gpa, leaf);
        }
        var nodes: u32 = 0;
        while (stack.pop()) |n| {
            if (r.visited.contains(n)) continue;
            if (nodes == 1) try r.spillNow();
            nodes += 1;
            try r.visited.put(r.gpa, n, {});
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            var h = r.live.rhead.items[n.int()];
            while (h != none) : (h = r.live.hnext[h]) try out.append(r.gpa, h);
            var link = r.live.phead.items[n.int()];
            while (link != none) : (link = r.live.lnext.items[link]) try stack.append(r.gpa, .from(link / 2));
        }
    }

    /// `several`: the holder's value there is one of several alternatives.
    const Hold = struct { path: PathId, d: CellId, approx: bool, several: bool = false };

    /// The paths at which holder value `n` (at `path`) holds candidate `d`,
    /// extended down to `c` when `d` is its trie ancestor: a walk of the
    /// explicit structure pruned by `reach` (§2.8). `false` paths come with
    /// a summary flag: held only at a summary position.
    fn holdPaths(r: *Resolver, n: NodeId, root: PathId, d: CellId, c: CellId, out: *std.ArrayList(Hold)) Error!void {
        // `alt`: reached through a union's side, one of several alternatives.
        // `cast`: below a recast, whose inner structure the cast's type may not
        // have: a step the outer place lacks stays at the cast's own path
        // (§2.13.9, #1136); `blur`: a hold kept so, approximate.
        const Frame_ = struct { node: NodeId, path: PathId, alt: bool = false, cast: bool = false, blur: bool = false };
        var stack: std.ArrayList(Frame_) = .empty;
        defer stack.deinit(r.gpa);
        // A node once per route state, its path and flags with it: a shared
        // nested holder (`t = { a = w, b = w }`) holds at every path it is
        // reached at, so a second route is walked, not dropped (§2.8 *Dead*,
        // #1223). Paths are canonical in the folded place graph, so the
        // states are finite and a cycle ends.
        var seen: Ids.FixedDict(3) = .{};
        defer seen.deinit(r.gpa);
        try stack.append(r.gpa, .{ .node = n, .path = root });
        const shapes = r.env.shapes;
        while (stack.pop()) |f| {
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            if (!r.env.cells.sets.member(try r.reach(f.node), d.int())) continue;
            const cells = try shapes.cellsOf(r.gpa, r.env.account(), &r.env.cells.sets, f.node);
            // A symbolic cell stands for what is below it only in a leaf: a
            // built node's children are explicit (a view's `[*]` is its
            // `others`), so there it is the object at its own path alone.
            const kind = shapes.kind(f.node);
            const explicit = kind == .node or kind == .delta;
            if (!(explicit and d != c)) if (r.env.cells.sets.get(cells, d.int())) |v| {
                var at = f.path;
                // `d` not `c`'s trie ancestor (a `⟲` relation): the path is where `d` is.
                if (d != c) {
                    r.steps.clearRetainingCapacity();
                    // A holder that is itself some level of a recursive
                    // value (`d` ends in `⟲`) holds `c` at that level: the
                    // path says so, `⟨T⟩` first.
                    const dx = r.env.cells.get(d);
                    if (try r.env.cells.stepsTo(r.env.places, d, c, r.gpa, &r.steps)) {
                        if (dx.origin.isSymbolic() and dx.origin != .top and r.env.places.pathParent(.from(dx.b)) != .none and r.env.places.pathStep(.from(dx.b)).kind == .level)
                            at = (try r.env.places.extend(r.gpa, r.env.charge, at, Step.level)) orelse at;
                        for (r.steps.items) |s| at = (try r.env.places.extend(r.gpa, r.env.charge, at, s)) orelse break;
                    }
                }
                try out.append(r.gpa, .{ .path = at, .d = d, .approx = v == 1 or f.blur, .several = f.alt or several(r.env.cells, cells) });
            };
            const k = shapes.get(f.node);
            const flags: u32 = @as(u32, @intFromBool(f.alt)) | @as(u32, @intFromBool(f.cast)) << 1 | @as(u32, @intFromBool(f.blur)) << 2;
            try r.env.charge.reserve(r.gpa, .memo, 1);
            if ((try seen.getOrPut(r.gpa, .{ f.node.int(), f.path.int(), flags })).found_existing) continue;
            switch (k.kind) {
                .leaf => {},
                .node, .delta => {
                    if (k.kind == .delta) try stack.append(r.gpa, .{ .node = .from(k.a), .path = f.path, .cast = f.cast, .blur = f.blur });
                    var it = shapes.overEntries(if (k.kind == .node) k.a else k.b);
                    while (it.next()) |e| {
                        const ext = try r.env.places.extend(r.gpa, r.env.charge, f.path, e.step);
                        const p = ext orelse if (f.cast) f.path else continue;
                        try stack.append(r.gpa, .{ .node = e.node, .path = p, .cast = f.cast, .blur = f.blur or ext == null });
                    }
                },
                .recast => try stack.append(r.gpa, .{ .node = .from(k.a), .path = f.path, .cast = true, .blur = f.blur }),
                .@"union", .choice, .positions => {
                    const alt = f.alt or k.kind == .@"union" or k.kind == .choice;
                    try stack.appendSlice(r.gpa, &.{ .{ .node = .from(k.a), .path = f.path, .alt = alt, .cast = f.cast, .blur = f.blur }, .{ .node = .from(k.b), .path = f.path, .alt = alt, .cast = f.cast, .blur = f.blur } });
                },
            }
        }
    }

    /// §2.7's queries for one held path: a use at or above it, after `p`
    /// and compatible, or (a list demand) a use under it. A `call` use
    /// counts where the callee's use shape names the path's remainder.
    fn laterUse(r: *Resolver, local: u32, q: PathId, p: u32) Error!?UseId {
        const Ctx = struct {
            r: *Resolver,
            q: PathId,
            fn accept(ctx: *anyopaque, u: Facts.Use, _: UseId) Error!bool {
                const s: *@This() = @ptrCast(@alignCast(ctx));
                if (u.kind != .call or u.use_node == .none) return true;
                // The steps of `q` below the use's own path.
                var steps: std.ArrayList(Step) = .empty;
                defer steps.deinit(s.r.gpa);
                const places = s.r.env.places;
                var at = s.q;
                while (at != .none and places.pathDepth(at) > places.pathDepth(u.path)) : (at = places.pathParent(at)) try steps.append(s.r.gpa, places.pathStep(at));
                if (at != u.path) return true; // below the queried path: any read counts
                std.mem.reverse(Step, steps.items);
                // The callee's use shape along the remainder: a path its place
                // graph cannot follow (a recast, an opaque type on the way) is
                // read as far as anyone knows; one it follows to no mark is not.
                var node = u.use_node;
                for (steps.items) |st| {
                    try s.r.env.charge.reserve(s.r.gpa, .inspection, 1);
                    if (s.r.env.shapes.kind(node) == .leaf) return s.r.env.shapes.cells(node) != .none;
                    node = (try s.r.env.shapes.proj(s.r.gpa, s.r.env.account(), places, s.r.env.cells, node, st)) orelse return true;
                }
                return s.r.env.shapes.cells(node) != .none;
            }
        };
        var ctx: Ctx = .{ .r = r, .q = q };
        const filter: Liveness.Filter = .{ .ctx = &ctx, .accept = Ctx.accept };
        // Each prefix of the held path on the demand's holder-slot step lane (#1225).
        const lanes: ?Liveness.Index.StepLanes = if (r.atom) |a| (if (r.env.account().inGrowth()) null else .{ .atom = a, .role = .direct_demand_query, .step = stepWord(.holder, 0) }) else null;
        const above = try r.frame.index.useAfterIn(r.gpa, r.env.charge, r.env.places, r.frame.regions, local, q, p, filter, lanes);
        const under = try r.frame.index.useUnderIn(r.gpa, r.env.charge, r.env.places, r.frame.regions, local, q, p, Liveness.Filter.all, lanes);
        if (above == null) return under;
        if (under == null) return above;
        const pa = r.frame.index.get(above.?).point;
        const pu = r.frame.index.get(under.?).point;
        return if (pu < pa) under else above;
    }

    /// Whether a cell set has two members or more: alternatives, of which a
    /// conflict on one is only possible (an approximate refusal, R-6.3).
    fn several(cellt: *const Cell.Table, s: SetId) bool {
        var it = cellt.sets.iterate(s);
        return it.next() != null and it.next() != null;
    }

    /// A refusal found for one (holder, path): `exact` the base cells it
    /// certainly holds there, each once (`last` the cell index last
    /// counted), and the cause of an exact hold if there is one.
    const Found = struct {
        holder: u32,
        path: PathId,
        point: u32,
        cause: Facts.Cause,
        approx: bool,
        use: UseId,
        exact: usize = 0,
        last: usize = std.math.maxInt(usize),
    };

    const FoundList = struct {
        items: std.ArrayList(Found) = .empty,
        index: Ids.FixedDict(2) = .{},

        fn deinit(l: *FoundList, gpa: Allocator) void {
            l.items.deinit(gpa);
            l.index.deinit(gpa);
        }
    };

    /// Record refusal `x` for base cell `ci`: one entry per (holder, path),
    /// its earliest use; an exact hold's cause wins over `element`.
    fn note(r: *Resolver, l: *FoundList, x: Found, ci: usize) Error!void {
        try r.env.charge.reserve(r.gpa, .inspection, 1);
        const got = try l.index.getOrPut(r.gpa, .{ x.holder, x.path.int() });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(l.items.items.len);
            var first = x;
            first.cause = if (x.approx) .element else x.cause;
            try l.items.append(r.gpa, first);
        }
        const y = &l.items.items[got.value_ptr.*];
        if (got.found_existing and x.point < y.point) {
            y.point = x.point;
            y.use = x.use;
        }
        if (x.approx or y.last == ci) return;
        if (y.exact == 0) y.cause = x.cause;
        y.last = ci;
        y.exact += 1;
    }

    fn isFresh(o: Cell.Origin) bool {
        return o == .site or o == .result;
    }

    fn resolve(r: *Resolver, dm: Demand) Error!Outcome {
        r.atom = dm.base_inst;
        defer r.atom = null;
        const deep = dm.kind.isDeep();
        const cellt = r.env.cells;
        const base_cells = if (deep) try r.reach(dm.base.node) else try r.env.shapes.cellsOf(r.gpa, r.env.account(), &r.env.cells.sets, dm.base.node);
        var out: Outcome = .{ .verdict = .accepted, .accepted = .fresh };
        // Several cells (alternatives, or a deep demand's reach) make every
        // query below a product of the demand with them: growth, chosen
        // here before the work, the list of them too (§4.1, *direct demand
        // query*; #1225: decided from the set before reading it).
        const product: ?Ids.Account.Kernel = if (several(cellt, base_cells)) try r.env.account().enter(r.gpa, null) else null;
        defer if (product) |k| r.env.account().leave(k);
        // The base's cells, in the order the conditions read them.
        var cells: std.ArrayList(Cell.Radix.Iterator.Entry) = .empty;
        defer cells.deinit(r.gpa);
        var it = cellt.sets.iterate(base_cells);
        while (it.next()) |e| {
            try r.env.charge.reserve(r.gpa, .inspection, 1);
            try cells.append(r.gpa, e);
            const o = cellt.origin(.from(e.key));
            if (!isFresh(o) and o != .mark) out.accepted = .param;
        }
        // A base with no cell holds no object: nothing to write.
        // 1. Known.
        for (cells.items) |e| if (cellt.origin(.from(e.key)) == .top) {
            return .{ .verdict = .refused, .cause = .unknown, .exactness = .approximate };
        };
        // 2. Unescaped; not shared (R-6.3's order: an escape first).
        for (cells.items) |e| {
            const c: CellId = .from(e.key);
            if (try r.escaped(c, dm.point, deep)) |_| return .{ .verdict = .refused, .cause = .escaped, .exactness = .approximate, .cell = c };
        }
        for (cells.items) |e| {
            const c: CellId = .from(e.key);
            if (cellt.origin(cellt.base(c)) == .shared) return .{ .verdict = .refused, .cause = .top_level, .exactness = .position, .cell = cellt.base(c) };
        }
        // 4. Disjoint: no other operand reaches a cell of the base.
        var relied: CondId = dm.relies;
        {
            // Every operand's reach against the base's cells: as large as the
            // operands, a product, so growth chosen before it, never the
            // demand's lane (§4.1, #1139).
            const sweep: ?Ids.Account.Kernel = if (product == null) try r.env.account().enter(r.gpa, null) else null;
            defer if (sweep) |k| r.env.account().leave(k);
            for (r.frame.operands[dm.operands.start..][0..dm.operands.len]) |op| {
                const rs = try r.reach(op.value.node);
                var ot = cellt.sets.iterate(rs);
                while (ot.next()) |x| {
                    for (cells.items) |e| {
                        try r.env.charge.reserve(r.gpa, .inspection, 1);
                        switch (r.conflict(.from(x.key), .from(e.key), deep)) {
                            .no => {},
                            .yes => return .{ .verdict = .refused, .cause = .disjoint, .exactness = if (x.value == 1 or e.value == 1) .approximate else .exact },
                            .under => |s| relied = try r.env.conds.@"and"(r.gpa, r.env.charge, relied, r.splitCond(s)),
                            .under_kappa => relied = Cond.lost,
                        }
                    }
                }
            }
        }
        // 5. Dead: the holders of every candidate, the one used first.
        // A shallow base of several cells is one of them: a hold of some of
        // them is a possible sharing; it is certain only when every cell of
        // the base is held there (R-6.3). So the refusals are gathered per
        // (holder, path) first, with the base cells they hit.
        const alternatives = !deep and several(cellt, base_cells);
        var found: FoundList = .{};
        defer found.deinit(r.gpa);
        var cands: std.ArrayList(CellId) = .empty;
        defer cands.deinit(r.gpa);
        var hs: std.ArrayList(u32) = .empty;
        defer hs.deinit(r.gpa);
        var holds: std.ArrayList(Hold) = .empty;
        defer holds.deinit(r.gpa);
        // A value spread or stored at k sites has k holders, and a demand on
        // it reads them all: k demands are k × k, a product. The demand's lane
        // sweeps one direct holder at one path (§4.1's *direct demand
        // query*); before the next holder's, radix node's or path's share the
        // sweep becomes growth, for the rest of the query (`spillNow`, #1201).
        var swept: u32 = 0;
        defer if (r.spill) |k| {
            r.env.account().leave(k);
            r.spill = null;
        };
        for (cells.items, 0..) |e, ci| {
            const c: CellId = .from(e.key);
            cands.clearRetainingCapacity();
            try r.candidates(c, deep, &cands);
            if (r.want_spill) {
                r.want_spill = false;
                try r.spillNow();
            }
            r.seen_holder.clear();
            for (cands.items) |d| {
                if (r.seen_holder.contains(d)) continue;
                try r.seen_holder.put(r.gpa, d, {});
                const how = r.conflict(d, c, deep);
                if (how == .no) continue;
                hs.clearRetainingCapacity();
                try r.holdersOf(d, &hs);
                for (hs.items) |hi| {
                    if (swept == 1) try r.spillNow();
                    swept += 1;
                    const h = r.frame.holders[hi];
                    // A holder of `⊤` counts only for what could have flowed into it
                    // (§2.8, #1102): a cell of its value that may be `c` or hold it. A
                    // `c` given to JavaScript before is refused at step 2 already.
                    if (cellt.origin(d) == .top and !try r.mayHaveReached(h.value.node, c, deep, cands.items)) continue;
                    switch (how) {
                        .no => unreachable,
                        .under => |s| {
                            relied = try r.env.conds.@"and"(r.gpa, r.env.charge, relied, r.splitCond(s));
                            continue;
                        },
                        .under_kappa => {
                            relied = Cond.lost;
                            continue;
                        },
                        .yes => if (r.otherPosition(dm, h, d)) |s| {
                            relied = try r.env.conds.@"and"(r.gpa, r.env.charge, relied, r.splitCond(s));
                            continue;
                        },
                    }
                    if (h.kind == .pending) {
                        if (!(h.start < dm.point and dm.point < h.end and r.compatible(h.start, dm.point))) continue;
                        try r.note(&found, .{ .holder = hi, .path = .none, .point = h.start, .cause = .held_operand, .approx = e.value == 1 or cellt.origin(d) == .top, .use = .none }, ci);
                        continue;
                    }
                    holds.clearRetainingCapacity();
                    {
                        // The walk of the holder's value is as large as it.
                        const walk = try r.env.account().enter(r.gpa, null);
                        defer r.env.account().leave(walk);
                        try r.holdPaths(h.value.node, h.root, d, c, &holds);
                    }
                    for (holds.items, 0..) |hold, hk| {
                        if (hk == 1) try r.spillNow();
                        const u = (try r.laterUse(h.who, hold.path, dm.point)) orelse continue;
                        // Held only at a summary position, or by a cell that
                        // itself stands for several objects (a level of a
                        // recursive value): maybe another one (§2.8's
                        // `element`). A holder above every level `c` may be
                        // holds them all: exact.
                        const summary = (r.env.places.isSummary(hold.path) or stands(cellt, r.env.places, hold.d)) and !isMaterialised(cellt, c);
                        const approx = hold.approx or e.value == 1 or summary or cellt.origin(hold.d) == .top;
                        const own = h.who == dm.base_local and (dm.base_path == .none or overlaps(r.env.places, hold.path, dm.base_path));
                        const cause: Facts.Cause = if (approx) .element else if (own) .later_use else .alias;
                        const several_held = hold.several and !r.env.places.isSummary(hold.path);
                        try r.note(&found, .{ .holder = hi, .path = hold.path, .point = r.frame.index.get(u).point, .cause = cause, .approx = approx or several_held, .use = u }, ci);
                    }
                }
            }
        }
        // An exact refusal wins over an approximate one; then the holder used
        // first (a pending operand by its start), ties to the earlier binding.
        var best: ?Outcome = null;
        var best_point: u32 = none;
        for (found.items.items) |x| {
            const inexact = if (alternatives) x.exact < cells.items.len else x.exact == 0;
            const better = if (best) |b|
                (b.exactness == .approximate and !inexact) or
                    ((b.exactness == .approximate) == inexact and (x.point < best_point or (x.point == best_point and r.frame.holders[x.holder].start < r.frame.holders[b.holder].start)))
            else
                true;
            if (!better) continue;
            best = .{ .verdict = .refused, .cause = x.cause, .exactness = if (inexact) .approximate else .exact, .holder = x.holder, .holder_path = x.path, .use = x.use };
            best_point = x.point;
        }
        if (best) |b| return b;
        // 6. Exclusive.
        switch (try r.env.conds.rely(r.gpa, r.env.charge, relied)) {
            .ok => {},
            .xreq => |atoms| out.xreq = atoms,
            .refused => |x| return .{ .verdict = .refused, .cause = .exclusive, .exactness = x },
        }
        return out;
    }

    /// The split under which holder `h` holds explicit cell `d` at another
    /// position than the demand's base (`Taken`): not one object if the
    /// split's κ held. Null when either is no such position.
    fn otherPosition(r: *Resolver, dm: Demand, h: Holder, d: CellId) ?Ids.SplitId {
        if (h.kind != .binding or h.taken.split == .none or dm.base_local == none) return null;
        if (dm.base_local >= r.frame.bindings.len) return null;
        const b = r.frame.bindings[dm.base_local];
        if (b == none) return null;
        const t = r.frame.holders[b].taken;
        if (t.split != h.taken.split or t.pos == h.taken.pos) return null;
        if (!r.env.cells.sets.member(t.explicit, d.int())) return null;
        return t.split;
    }

    fn splitCond(r: *Resolver, s: Ids.SplitId) CondId {
        const k = r.env.cells.splitOf(s).cond;
        return if (k == .none) Cond.lost else k;
    }

    /// A refinement a split took: one position, not the summary.
    fn isMaterialised(cellt: *const Cell.Table, c: CellId) bool {
        var at = c;
        // A recursive child of a taken position is that position's own.
        while (cellt.origin(at) == .below) at = cellt.parent(at);
        const o = cellt.origin(at);
        return o == .elem or o == .level;
    }

    /// A symbolic cell at or below a summary position (`[*]`, `⟲`).
    fn stands(cellt: *const Cell.Table, places: *const Cell.Places, c: CellId) bool {
        const x = cellt.get(c);
        return x.origin.isSymbolic() and x.origin != .top and places.isSummary(.from(x.b));
    }

    /// One path a prefix of the other.
    fn overlaps(places: *const Cell.Places, a: PathId, b: PathId) bool {
        return places.isPrefix(a, b) or places.isPrefix(b, a);
    }
};

/// Resolve every demand of `frame` in evaluation order (§2.8): at each
/// point, the demands there first, then the holders it starts, then the
/// holders whose last use it was. One outcome per demand, in its order.
pub fn resolve(env: Env, frame: Frame, out: []Outcome) Error!void {
    std.debug.assert(out.len == frame.demands.len);
    const gpa = env.gpa;
    var r: Resolver = .{ .gpa = gpa, .env = env, .frame = frame, .live = .{ .gpa = gpa, .env = env } };
    defer r.deinit();
    const n = frame.holders.len;
    r.live.hnext = try gpa.alloc(u32, n);
    r.live.hprev = try gpa.alloc(u32, n);
    r.on = try gpa.alloc(bool, n);
    @memset(r.on, false);
    try r.buildEscapes();
    // Holders by start and by end.
    const by_start = try gpa.alloc(u32, n);
    defer gpa.free(by_start);
    const by_end = try gpa.alloc(u32, n);
    defer gpa.free(by_end);
    for (by_start, by_end, 0..) |*s, *e, i| {
        s.* = @intCast(i);
        e.* = @intCast(i);
    }
    const Ord = struct {
        hs: []const Holder,
        fn byStart(c: @This(), a: u32, b: u32) bool {
            return c.hs[a].start < c.hs[b].start or (c.hs[a].start == c.hs[b].start and a < b);
        }
        fn byEnd(c: @This(), a: u32, b: u32) bool {
            return c.hs[a].end < c.hs[b].end or (c.hs[a].end == c.hs[b].end and a < b);
        }
    };
    std.mem.sort(u32, by_start, Ord{ .hs = frame.holders }, Ord.byStart);
    std.mem.sort(u32, by_end, Ord{ .hs = frame.holders }, Ord.byEnd);
    // The demands by point (stable: two at one point keep their order).
    const order = try gpa.alloc(u32, frame.demands.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const DOrd = struct {
        ds: []const Demand,
        fn less(c: @This(), a: u32, b: u32) bool {
            return c.ds[a].point < c.ds[b].point or (c.ds[a].point == c.ds[b].point and a < b);
        }
    };
    std.mem.sort(u32, order, DOrd{ .ds = frame.demands }, DOrd.less);
    var si: usize = 0;
    var ei: usize = 0;
    var di: usize = 0;
    while (di < order.len or si < n or ei < n) {
        // The next point anything happens at.
        var p: u32 = none;
        if (di < order.len) p = @min(p, frame.demands[order[di]].point);
        if (si < n) p = @min(p, frame.holders[by_start[si]].start);
        if (ei < n) p = @min(p, frame.holders[by_end[ei]].end);
        while (di < order.len and frame.demands[order[di]].point == p) : (di += 1) {
            // §4.1: a written demand's query is its own kernel, keyed by the
            // demand's base: two demands at one call are two lanes.
            const kernel = try env.account().enter(gpa, .{ .atom = frame.demands[order[di]].base_inst, .role = .direct_demand_query });
            defer env.account().leave(kernel);
            out[order[di]] = try r.resolve(frame.demands[order[di]]);
        }
        while (si < n and frame.holders[by_start[si]].start == p) : (si += 1) {
            const h = by_start[si];
            if (frame.holders[h].value.node == .none) continue;
            const root = try r.reach(frame.holders[h].value.node);
            if (root == .none) continue;
            const kernel = try env.account().enter(gpa, try r.holderLane(frame.holders[h], root));
            defer env.account().leave(kernel);
            try r.live.register(h, root);
            r.on[h] = true;
        }
        while (ei < n and frame.holders[by_end[ei]].end == p) : (ei += 1) {
            const h = by_end[ei];
            if (!r.on[h]) continue;
            // A holder that ends where it starts expires once registered.
            if (frame.holders[h].start > p) continue;
            const root = try r.reach(frame.holders[h].value.node);
            const kernel = try env.account().enter(gpa, try r.holderLane(frame.holders[h], root));
            defer env.account().leave(kernel);
            try r.live.expire(h, root);
            r.on[h] = false;
        }
    }
}

comptime {
    Ids.assertRecord(Demand);
    Ids.assertRecord(Holder);
    Ids.assertRecord(Outcome);
    Ids.assertRecord(Live.AnchorLink);
}
