//! own3, layer 1: locations (research report 110 §6.2, report 111 §2).
//!
//! A **location** names the cells of a value by the type alone. It is a path
//! of labels through the place graph (`own2/Place.zig`).
//!
//! - Outside a cycle of the type, a location is the path of steps to a place.
//! - Inside a cycle, the **entry level** is every place that a path reaches
//!   before it comes back to a place it left: these have their own locations,
//!   as outside a cycle. Everything past the first return is the **deep
//!   level**: one location for each object place of the cycle (a `member`
//!   label) and one for each step out of it (a label with `cyc`), whatever the
//!   depth and the route. This is the option of report 110 §6.2.
//!
//! So the list of a tree's root node and the lists of its deeper nodes are
//! two locations, and a function that writes the first does not ask for the
//! second.
//!
//! Labels hold no id of a module (a field's text rank, a constructor's
//! ordinal, a type's `TypeId`), so a location means the same in the callee's
//! module and in the caller's. The **call map** (`cover`) is the identity on
//! label paths, a callee's type variable covers every caller location below
//! it, and one fallback is sound for the case where a type argument closes a
//! cycle that the signature does not have.
//!
//! A **layout** is the list of the locations of one type, in a fixed order.
//! A value's facts are indexed by layout entry. A layout with no entry is a
//! type that holds no object: most values of a program.
//!
//! A **path** is a chain of concrete steps from a root value of one frame
//! (`x`, `x#Node.1`, `x.items`). Two paths of one root name parts that can
//! share a cell only when one is a prefix of the other.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("../own2/Ids.zig");
const Place = @import("../own2/Place.zig");

pub const PlaceId = Ids.PlaceId;
pub const Step = Place.Step;
pub const none: u32 = std.math.maxInt(u32);
/// In a cover: every entry of the signature's layout covers this one.
pub const all: u32 = std.math.maxInt(u32) - 1;

/// Whether cover value `c` says that signature entry `se` covers the entry.
pub fn hits(c: u32, se: u32) bool {
    return c == se or c == all;
}

pub const LabelKind = enum(u4) { field, index, ctor_arg, elem, contents, row, member, env, slot };

/// One label of a location. `head` is the head of the place the step leaves
/// (a `TypeId`, a tuple's arity, 0 for a record); `cyc` says that the label is
/// of the deep level of a cycle: the step at every depth.
pub const Label = packed struct(u64) {
    payload: u27,
    cyc: bool,
    kind: LabelKind,
    head: u32,

    pub fn word(l: Label) u64 {
        return @bitCast(l);
    }
};

/// What a location's cell is, as the write rule reads it.
pub const Kind = enum(u8) {
    /// A list: the one kind a write edits.
    list,
    /// A type variable: every object below it.
    @"var",
    /// A function value: what it captured.
    closure,
    /// A foreign value that does not cross: JavaScript's.
    @"opaque",
    /// A cell (`Ref`, `Deferred`): its contents are never `own`.
    cell,

    pub fn wide(k: Kind) bool {
        return k != .list;
    }
};

pub const Entry = struct {
    loc: u32,
    kind: Kind,
    /// No element step and no deep level on the way: the location names one
    /// value (one list cell, or the one value at a type variable). If not, it
    /// is a summary: it names the cells of many positions.
    single: bool,
};

pub const Proj = struct {
    child: PlaceId,
    /// Per entry of the child's layout: the entry of the parent's layout.
    up: []const u32,
    /// Per entry of the parent's layout: the child's entries there, a run of `down`.
    down_off: []const u32,
    down: []const u32,

    pub fn downOf(p: *const Proj, e: u32) []const u32 {
        return p.down[p.down_off[e]..p.down_off[e + 1]];
    }
};

const LocKey = struct { parent: u32, label: u64 };
const ProjKey = struct { place: u32, step: u32 };
const PathKey = struct { parent: u32, step: u32 };
const CoverKey = struct { sig: u32, of: u32 };

pub const Path = struct {
    parent: u32,
    step: u32,
    place: PlaceId,
    depth: u32,
    /// Per entry of `place`'s layout: the entry of the root's layout.
    to_root: []const u32,
};

pub const Table = struct {
    gpa: Allocator,
    arena: Allocator,
    places: *Place.Table,

    loc_parent: std.ArrayList(u32) = .empty,
    loc_label: std.ArrayList(u64) = .empty,
    loc_summary: std.ArrayList(bool) = .empty,
    loc_depth: std.ArrayList(u32) = .empty,
    loc_index: std.AutoHashMapUnmanaged(LocKey, u32) = .empty,

    /// Each layout's entries, in `arena`: a slice of them stays good while the table grows.
    layouts: std.ArrayList([]const Entry) = .empty,
    /// Per layout of a place, per entry: the steps of one path from the place to a cell there.
    reps: std.ArrayList([]const []const u32) = .empty,
    /// Per place: its layout, or `none` while not built.
    layout_of: std.ArrayList(u32) = .empty,

    projs: std.ArrayList(*const Proj) = .empty,
    proj_index: std.AutoHashMapUnmanaged(ProjKey, u32) = .empty,

    paths: std.ArrayList(Path) = .empty,
    path_index: std.AutoHashMapUnmanaged(PathKey, u32) = .empty,
    /// Per place: its root path, or `none`.
    path_root: std.ArrayList(u32) = .empty,

    covers: std.AutoHashMapUnmanaged(CoverKey, []const u32) = .empty,
    empty_layout: u32 = none,

    pub fn init(gpa: Allocator, arena: Allocator, places: *Place.Table) Allocator.Error!Table {
        var t: Table = .{ .gpa = gpa, .arena = arena, .places = places };
        // Location 0 is the empty path.
        try t.loc_parent.append(gpa, none);
        try t.loc_label.append(gpa, 0);
        try t.loc_summary.append(gpa, false);
        try t.loc_depth.append(gpa, 0);
        t.empty_layout = try t.addLayout(&.{});
        return t;
    }

    pub fn deinit(t: *Table) void {
        const gpa = t.gpa;
        t.loc_parent.deinit(gpa);
        t.loc_label.deinit(gpa);
        t.loc_summary.deinit(gpa);
        t.loc_depth.deinit(gpa);
        t.loc_index.deinit(gpa);
        t.layouts.deinit(gpa);
        t.reps.deinit(gpa);
        t.layout_of.deinit(gpa);
        t.projs.deinit(gpa);
        t.proj_index.deinit(gpa);
        t.paths.deinit(gpa);
        t.path_index.deinit(gpa);
        t.path_root.deinit(gpa);
        t.covers.deinit(gpa);
    }

    // ---- the location trie ---------------------------------------------------

    pub fn extend(t: *Table, parent: u32, label: Label) Allocator.Error!u32 {
        const got = try t.loc_index.getOrPut(t.gpa, .{ .parent = parent, .label = label.word() });
        if (got.found_existing) return got.value_ptr.*;
        const id: u32 = @intCast(t.loc_parent.items.len);
        got.value_ptr.* = id;
        try t.loc_parent.append(t.gpa, parent);
        try t.loc_label.append(t.gpa, label.word());
        try t.loc_summary.append(t.gpa, t.loc_summary.items[parent] or label.cyc or label.kind == .elem or label.kind == .member or label.kind == .row);
        try t.loc_depth.append(t.gpa, t.loc_depth.items[parent] + 1);
        return id;
    }

    /// `extend`, when the location exists already.
    pub fn find(t: *const Table, parent: u32, label: u64) ?u32 {
        return t.loc_index.get(.{ .parent = parent, .label = label });
    }

    /// Whether location `a` is `b` or above it.
    pub fn isPrefix(t: *const Table, a: u32, b: u32) bool {
        const da = t.loc_depth.items[a];
        var x = b;
        while (t.loc_depth.items[x] > da) x = t.loc_parent.items[x];
        return x == a;
    }

    /// The labels of `loc`, from the root.
    pub fn labels(t: *const Table, loc: u32, out: *std.ArrayList(u64), gpa: Allocator) Allocator.Error!void {
        const at = out.items.len;
        var x = loc;
        while (x != 0) : (x = t.loc_parent.items[x]) try out.append(gpa, t.loc_label.items[x]);
        std.mem.reverse(u64, out.items[at..]);
    }

    /// `prefix` followed by the labels of `loc`.
    pub fn concat(t: *Table, prefix: u32, loc: u32) Allocator.Error!u32 {
        if (loc == 0) return prefix;
        if (prefix == 0) return loc;
        const up = try t.concat(prefix, t.loc_parent.items[loc]);
        return t.extend(up, @bitCast(t.loc_label.items[loc]));
    }

    /// The location above `loc`'s first label of a deep level, or `none` when it has no such label.
    fn deepEntry(t: *const Table, loc: u32) u32 {
        var x = loc;
        var top: u32 = none;
        while (x != 0) : (x = t.loc_parent.items[x]) {
            const l: Label = @bitCast(t.loc_label.items[x]);
            if (l.cyc) top = t.loc_parent.items[x];
        }
        return top;
    }

    // ---- layouts ---------------------------------------------------------------

    pub fn addLayout(t: *Table, es: []const Entry) Allocator.Error!u32 {
        const id: u32 = @intCast(t.layouts.items.len);
        try t.layouts.append(t.gpa, try t.arena.dupe(Entry, es));
        try t.reps.append(t.gpa, &.{});
        return id;
    }

    pub fn layoutEntries(t: *const Table, id: u32) []const Entry {
        return t.layouts.items[id];
    }

    fn objectKind(k: Place.Kind) ?Kind {
        return switch (k) {
            .list => .list,
            .@"var" => .@"var",
            .closure => .closure,
            .@"opaque", .dict => .@"opaque",
            .ref => .cell,
            .record, .tuple, .ctor, .cross => null,
        };
    }

    fn stepLabel(t: *const Table, from: PlaceId, s: Step, cyc: bool) Label {
        const head = t.places.head(from);
        return switch (s.kind) {
            .field => .{ .kind = .field, .payload = @intCast(s.payload & 0x7ffffff), .cyc = cyc, .head = 0 },
            .index => .{ .kind = .index, .payload = @intCast(s.payload & 0x7ffffff), .cyc = cyc, .head = 0 },
            .ctor_arg => blk: {
                const ca = t.places.ctorArgOf(s);
                break :blk .{ .kind = .ctor_arg, .payload = @intCast(((ca[0] & 0x7fff) << 12) | (ca[1] & 0xfff)), .cyc = cyc, .head = head };
            },
            .elem => .{ .kind = .elem, .payload = 0, .cyc = cyc, .head = 0 },
            .contents => .{ .kind = .contents, .payload = 0, .cyc = cyc, .head = 0 },
            .env => .{ .kind = .env, .payload = 0, .cyc = cyc, .head = 0 },
            .slot => .{ .kind = .slot, .payload = @intCast(s.payload & 0x7ffffff), .cyc = cyc, .head = head },
            .row, .level => .{ .kind = .row, .payload = 0, .cyc = cyc, .head = 0 },
        };
    }

    fn memberLabel(t: *const Table, m: PlaceId, k: Kind) Label {
        return .{ .kind = .member, .payload = @backingInt(k), .cyc = true, .head = t.places.head(m) };
    }

    const Building = struct {
        out: std.ArrayList(Entry) = .empty,
        /// Per entry of `out`: its path, a run of `rep_steps`.
        rep_at: std.ArrayList([2]u32) = .empty,
        rep_steps: std.ArrayList(u32) = .empty,
        /// The steps from the root to the place in work.
        steps: std.ArrayList(u32) = .empty,
        /// The places of the cycle in work that the path is on.
        on_path: std.ArrayList(u32) = .empty,
        /// `(scc, entry prefix)` pairs whose deep level is done, and its members.
        seen_scc: std.ArrayList([2]u32) = .empty,
        members: std.ArrayList(u32) = .empty,

        fn deinit(b: *Building, gpa: Allocator) void {
            b.out.deinit(gpa);
            b.rep_at.deinit(gpa);
            b.rep_steps.deinit(gpa);
            b.steps.deinit(gpa);
            b.on_path.deinit(gpa);
            b.seen_scc.deinit(gpa);
            b.members.deinit(gpa);
        }
    };

    /// The layout of `place`: every location at and below it.
    pub fn layoutOf(t: *Table, place: PlaceId) Allocator.Error!u32 {
        const pi = place.int();
        if (pi >= t.layout_of.items.len) try t.layout_of.appendNTimes(t.gpa, none, @as(usize, t.places.count()) + 1 - t.layout_of.items.len);
        const have = t.layout_of.items[pi];
        if (have != none) return have;
        if (t.places.holds(place).isEmpty()) {
            t.layout_of.items[pi] = t.empty_layout;
            return t.empty_layout;
        }
        var b: Building = .{};
        defer b.deinit(t.gpa);
        try t.visit(&b, place, 0);
        var id = t.empty_layout;
        if (b.out.items.len != 0) {
            id = try t.addLayout(b.out.items);
            const reps = try t.arena.alloc([]const u32, b.out.items.len);
            for (reps, b.rep_at.items) |*r, at| r.* = try t.arena.dupe(u32, b.rep_steps.items[at[0]..][0..at[1]]);
            t.reps.items[id] = reps;
        }
        t.layout_of.items[pi] = id;
        return id;
    }

    fn addEntry(t: *Table, b: *Building, loc: u32, kind: Kind) Allocator.Error!void {
        for (b.out.items) |*e| if (e.loc == loc) {
            // Two places at one location (the deep level of a cycle): the wider kind.
            if (e.kind != kind) e.kind = .@"var";
            return;
        };
        try b.out.append(t.gpa, .{ .loc = loc, .kind = kind, .single = !t.loc_summary.items[loc] });
        try b.rep_at.append(t.gpa, .{ @intCast(b.rep_steps.items.len), @intCast(b.steps.items.len) });
        try b.rep_steps.appendSlice(t.gpa, b.steps.items);
    }

    /// A place reached by a step that does not stay in a cycle: `loc` is its own location.
    fn visit(t: *Table, b: *Building, place: PlaceId, loc: u32) Allocator.Error!void {
        if (t.places.holds(place).isEmpty()) return;
        if (t.places.cyclic(place)) {
            const base = b.on_path.items.len;
            try b.on_path.append(t.gpa, place.int());
            try t.visitEntry(b, place, loc, loc, base);
            b.on_path.shrinkRetainingCapacity(base);
            return;
        }
        if (objectKind(t.places.kind(place))) |k| {
            try t.addEntry(b, loc, k);
            // What a cell holds is never `own`, and nothing is below a
            // variable, a function or a foreign value.
            if (k != .list) return;
        }
        const st = t.places.steps(place);
        for (st.steps, st.children) |s, c| {
            if (s.kind == .level) continue;
            try b.steps.append(t.gpa, s.word());
            try t.visit(b, c, try t.extend(loc, t.stepLabel(place, s, false)));
            _ = b.steps.pop();
        }
    }

    /// The entry level of a cycle entered at `entry`: `place` is on the path, at `loc`.
    fn visitEntry(t: *Table, b: *Building, place: PlaceId, loc: u32, entry: u32, base: usize) Allocator.Error!void {
        if (objectKind(t.places.kind(place))) |k| {
            try t.addEntry(b, loc, k);
            if (k != .list) return;
        }
        const st = t.places.steps(place);
        for (st.steps, st.children) |s, c| {
            if (s.kind == .level) continue;
            try b.steps.append(t.gpa, s.word());
            if (t.places.sameComponent(place, c)) {
                if (std.mem.indexOfScalar(u32, b.on_path.items[base..], c.int()) != null) {
                    // The path comes back: everything from here is the deep level.
                    try t.visitDeep(b, c, entry);
                } else {
                    try b.on_path.append(t.gpa, c.int());
                    try t.visitEntry(b, c, try t.extend(loc, t.stepLabel(place, s, false)), entry, base);
                    _ = b.on_path.pop();
                }
            } else try t.visit(b, c, try t.extend(loc, t.stepLabel(place, s, false)));
            _ = b.steps.pop();
        }
    }

    /// The deep level of the cycle of `place`, entered at the location `entry`: each member once.
    fn visitDeep(t: *Table, b: *Building, place: PlaceId, entry: u32) Allocator.Error!void {
        const scc = t.places.sccOf(place);
        for (b.seen_scc.items) |x| if (x[0] == scc and x[1] == entry) return;
        try b.seen_scc.append(t.gpa, .{ scc, entry });
        const mbase = b.members.items.len;
        try t.deepMember(b, place, entry, mbase);
        b.members.shrinkRetainingCapacity(mbase);
    }

    fn deepMember(t: *Table, b: *Building, m: PlaceId, entry: u32, mbase: usize) Allocator.Error!void {
        if (std.mem.indexOfScalar(u32, b.members.items[mbase..], m.int()) != null) return;
        try b.members.append(t.gpa, m.int());
        if (objectKind(t.places.kind(m))) |k| {
            try t.addEntry(b, try t.extend(entry, t.memberLabel(m, k)), k);
            if (k != .list) return;
        }
        const st = t.places.steps(m);
        for (st.steps, st.children) |s, c| {
            if (s.kind == .level) continue;
            try b.steps.append(t.gpa, s.word());
            if (t.places.sameComponent(m, c)) {
                try t.deepMember(b, c, entry, mbase);
            } else try t.visit(b, c, try t.extend(entry, t.stepLabel(m, s, true)));
            _ = b.steps.pop();
        }
    }

    /// The location, in `root`'s layout, of the cell that the steps `steps` reach from `root`; null when they reach none.
    fn abstractPath(t: *Table, root: PlaceId, steps: []const u32) Allocator.Error!?u32 {
        var loc: u32 = 0;
        var cur = root;
        var on_path: std.ArrayList(u32) = .empty;
        defer on_path.deinit(t.gpa);
        var in_cycle = t.places.cyclic(root);
        var entry: u32 = 0;
        var deep = false;
        if (in_cycle) try on_path.append(t.gpa, root.int());
        for (steps) |w| {
            const s = Step.fromWord(w);
            const next = t.places.child(cur, s) orelse return null;
            if (in_cycle and t.places.sameComponent(cur, next)) {
                if (!deep) {
                    if (std.mem.indexOfScalar(u32, on_path.items, next.int()) != null) {
                        deep = true;
                        loc = entry;
                    } else {
                        loc = try t.extend(loc, t.stepLabel(cur, s, false));
                        try on_path.append(t.gpa, next.int());
                    }
                }
            } else {
                loc = try t.extend(if (deep) entry else loc, t.stepLabel(cur, s, deep));
                deep = false;
                in_cycle = t.places.cyclic(next);
                entry = loc;
                on_path.clearRetainingCapacity();
                if (in_cycle) try on_path.append(t.gpa, next.int());
            }
            cur = next;
        }
        if (deep) {
            const k = objectKind(t.places.kind(cur)) orelse return null;
            return try t.extend(entry, t.memberLabel(cur, k));
        }
        return loc;
    }

    /// The location of `place`'s own cell in its own layout, or `none` when it is no object.
    pub fn selfLoc(t: *Table, place: PlaceId) Allocator.Error!u32 {
        _ = objectKind(t.places.kind(place)) orelse return none;
        return 0;
    }

    fn indexOfLoc(es: []const Entry, loc: u32) u32 {
        for (es, 0..) |e, i| if (e.loc == loc) return @intCast(i);
        return none;
    }

    // ---- projections -----------------------------------------------------------

    /// The step `s` out of `place`: the child's place and the two maps between
    /// the layouts. Null when the place has no such step.
    pub fn proj(t: *Table, place: PlaceId, s: Step) Allocator.Error!?*const Proj {
        const key: ProjKey = .{ .place = place.int(), .step = s.word() };
        if (t.proj_index.get(key)) |i| return if (i == none) null else t.projs.items[i];
        const child = t.places.child(place, s) orelse {
            try t.proj_index.put(t.gpa, key, none);
            return null;
        };
        const pl = try t.layoutOf(place);
        const cl = try t.layoutOf(child);
        const pn = t.layouts.items[pl].len;
        const cn = t.layouts.items[cl].len;
        const up = try t.arena.alloc(u32, cn);
        var steps: std.ArrayList(u32) = .empty;
        defer steps.deinit(t.gpa);
        for (0..cn) |j| {
            steps.clearRetainingCapacity();
            try steps.append(t.gpa, s.word());
            try steps.appendSlice(t.gpa, t.reps.items[cl][j]);
            const ploc = (try t.abstractPath(place, steps.items)) orelse {
                up[j] = none;
                continue;
            };
            up[j] = indexOfLoc(t.layoutEntries(pl), ploc);
        }
        // The inverse: per entry of the parent, the child's entries there.
        const down_off = try t.arena.alloc(u32, pn + 1);
        const down = try t.arena.alloc(u32, cn);
        var n: u32 = 0;
        for (0..pn) |i| {
            down_off[i] = n;
            for (up, 0..) |u, j| if (u == i) {
                down[n] = @intCast(j);
                n += 1;
            };
        }
        down_off[pn] = n;
        const id: u32 = @intCast(t.projs.items.len);
        const pr = try t.arena.create(Proj);
        pr.* = .{ .child = child, .up = up, .down_off = down_off, .down = down[0..n] };
        try t.projs.append(t.gpa, pr);
        try t.proj_index.put(t.gpa, key, id);
        return pr;
    }

    // ---- paths -------------------------------------------------------------------

    pub fn pathRoot(t: *Table, place: PlaceId) Allocator.Error!u32 {
        const pi = place.int();
        if (pi >= t.path_root.items.len) try t.path_root.appendNTimes(t.gpa, none, @as(usize, t.places.count()) + 1 - t.path_root.items.len);
        if (t.path_root.items[pi] != none) return t.path_root.items[pi];
        const n = t.layouts.items[try t.layoutOf(place)].len;
        const ident = try t.arena.alloc(u32, n);
        for (ident, 0..) |*x, i| x.* = @intCast(i);
        const id: u32 = @intCast(t.paths.items.len);
        try t.paths.append(t.gpa, .{ .parent = none, .step = 0, .place = place, .depth = 0, .to_root = ident });
        t.path_root.items[pi] = id;
        return id;
    }

    /// `path` extended by step `s`, or null when its place has no such step.
    pub fn pathExtend(t: *Table, path: u32, s: Step) Allocator.Error!?u32 {
        const key: PathKey = .{ .parent = path, .step = s.word() };
        if (t.path_index.get(key)) |i| return if (i == none) null else i;
        const p = t.paths.items[path];
        const pr = (try t.proj(p.place, s)) orelse {
            try t.path_index.put(t.gpa, key, none);
            return null;
        };
        const to_root = try t.arena.alloc(u32, pr.up.len);
        for (to_root, pr.up) |*x, u| x.* = if (u == none) none else p.to_root[u];
        const id: u32 = @intCast(t.paths.items.len);
        try t.paths.append(t.gpa, .{ .parent = path, .step = s.word(), .place = pr.child, .depth = p.depth + 1, .to_root = to_root });
        try t.path_index.put(t.gpa, key, id);
        return id;
    }

    /// Whether one of the two paths is a prefix of the other.
    pub fn comparable(t: *const Table, a: u32, b: u32) bool {
        if (a == b) return true;
        var x = a;
        var y = b;
        const da = t.paths.items[x].depth;
        const db = t.paths.items[y].depth;
        if (da > db) {
            while (t.paths.items[x].depth > db) x = t.paths.items[x].parent;
        } else {
            while (t.paths.items[y].depth > da) y = t.paths.items[y].parent;
        }
        return x == y;
    }

    /// Whether path `a` is `b` or above it.
    pub fn pathPrefix(t: *const Table, a: u32, b: u32) bool {
        const da = t.paths.items[a].depth;
        var y = b;
        if (t.paths.items[y].depth < da) return false;
        while (t.paths.items[y].depth > da) y = t.paths.items[y].parent;
        return y == a;
    }

    // ---- the call map ----------------------------------------------------------

    /// Per entry of layout `of` (a caller's type), the entry of layout `sig`
    /// (a signature's type) that covers it: the same location, or a wide
    /// location (a type variable, a row) above it.
    ///
    /// A type argument can name the container again (`List Node`, where a
    /// `Node` holds a `List Node`): the caller's type then has a cycle that
    /// the signature's type does not have. A caller location of that cycle's
    /// deep level is covered by the signature's wide location inside the
    /// cycle's entry level, when there is exactly one. In each other case that
    /// no rule names, the answer is `all`: every signature entry covers it.
    pub fn cover(t: *Table, sig: u32, of: u32) Allocator.Error![]const u32 {
        const key: CoverKey = .{ .sig = sig, .of = of };
        if (t.covers.get(key)) |m| return m;
        const se = t.layoutEntries(sig);
        const oe = t.layoutEntries(of);
        const m = try t.arena.alloc(u32, oe.len);
        const row: Label = .{ .kind = .row, .payload = 0, .cyc = false, .head = 0 };
        for (m, oe) |*x, e| {
            x.* = none;
            var a = e.loc;
            while (true) {
                const i = indexOfLoc(se, a);
                if (i != none and (a == e.loc or se[i].kind.wide())) {
                    x.* = i;
                    break;
                }
                if (a == 0) break;
                a = t.loc_parent.items[a];
                // A field that the signature's record does not name is in its row.
                if (t.find(a, row.word())) |r| {
                    const ri = indexOfLoc(se, r);
                    if (ri != none) {
                        x.* = ri;
                        break;
                    }
                }
            }
            if (x.* != none or se.len == 0) continue;
            x.* = all;
            const entry = t.deepEntry(e.loc);
            if (entry == none) continue;
            var one: u32 = none;
            var count: u32 = 0;
            for (se, 0..) |s, i| if (s.kind.wide() and t.isPrefix(entry, s.loc)) {
                one = @intCast(i);
                count += 1;
            };
            if (count == 1) x.* = one;
        }
        try t.covers.put(t.gpa, key, m);
        return m;
    }
};
