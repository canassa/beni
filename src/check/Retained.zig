//! The checker's working lists, kept by a worker from one module to the next
//! (checker-v2.md §4.1).
//!
//! The solver and the constraint generator build the same lists for every
//! module, every binding group and every frame: a group's tree and young
//! pool, a frame's pool and open-`?` list, the walks' stacks, the
//! obligation tables. Made fresh each time, they grew from empty on the
//! process allocator, over and over, for as long as a check ran. Here each
//! is made once per worker and handed out cleared, so a module that fits in
//! what an earlier one needed allocates none of them.
//!
//! **Handed out by moving.** A list is moved into the structure that uses
//! it and moved back, cleared, when that structure is done with it; while it
//! is out, its slot here is empty. So nothing is shared: a list lent twice
//! would be two owners of one buffer, and a list never given back (an error
//! path) is freed by its user and simply made again next time.
//!
//! **By depth.** A frame's lists belong to its depth on the frame stack
//! (its rank, `Generalize.pushFrame`), and a group's generator lists and
//! tree to its nesting level (`Groups.check`): both are strictly nested, so
//! one set per depth is never lent to two frames at once. These are the
//! per-rank pools of Elm's and Roc's generalisation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TypeStore = @import("TypeStore.zig");
const Obligations = @import("Obligations.zig");
const Walk = @import("Walk.zig");
const Generalize = @import("Generalize.zig");
const Tree = @import("constrain/Tree.zig");
const EnvFile = @import("Env.zig");
const stamped = @import("../stamped.zig");

const Retained = @This();

const Var = TypeStore.Var;

/// Per nesting level of group checks: the group's constraint tree and the
/// generator's lists. Heap-allocated once, so a level's address is stable
/// while deeper levels are added.
levels: std.ArrayList(*Level) = .empty,
/// Per frame depth: the frame's young pool and open-`?` list.
frames_at: std.ArrayList(FrameLists) = .empty,
/// The solver's own, per module: its frame stack, captures, walk stacks and
/// obligation tables.
frames: std.ArrayList(Generalize.Frame) = .empty,
captures: std.ArrayList(Generalize.Capture) = .empty,
stacks: Walk.Stacks = .{},
obligations: Obligations = .{},
/// Resolution's variable sets at a boundary (`Resolve.close`,
/// `holdLet`, `closeLet`): columns over the store's variables, emptied by
/// one increment each time a boundary starts one, whatever the module.
boundary: Boundary = .{},

pub const VarSet = stamped.Column(Var, void);

pub const Boundary = struct {
    promoted: VarSet = .{},
    by_function: VarSet = .{},
    by_value: VarSet = .{},
    held: stamped.Column(Var, EnvFile.Monomorphic.Why) = .{},
    own: VarSet = .{},
    listed: VarSet = .{},

    fn deinit(b: *Boundary, gpa: Allocator) void {
        b.promoted.deinit(gpa);
        b.by_function.deinit(gpa);
        b.by_value.deinit(gpa);
        b.held.deinit(gpa);
        b.own.deinit(gpa);
        b.listed.deinit(gpa);
    }
};

pub const Level = struct {
    tree: Tree.Tree = .{},
    pool: std.ArrayList(Var) = .empty,
    frame_binders: std.ArrayList(u32) = .empty,
    frame_annotated: std.ArrayList(u32) = .empty,
    targets: std.ArrayList(Tree.Generator.Target) = .empty,

    fn deinit(l: *Level, gpa: Allocator) void {
        l.tree.deinit(gpa);
        l.pool.deinit(gpa);
        l.frame_binders.deinit(gpa);
        l.frame_annotated.deinit(gpa);
        l.targets.deinit(gpa);
    }
};

pub const FrameLists = struct {
    pool: std.ArrayList(Var) = .empty,
    tries: std.ArrayList(u32) = .empty,

    fn deinit(f: *FrameLists, gpa: Allocator) void {
        f.pool.deinit(gpa);
        f.tries.deinit(gpa);
    }
};

pub fn deinit(r: *Retained, gpa: Allocator) void {
    for (r.levels.items) |l| {
        l.deinit(gpa);
        gpa.destroy(l);
    }
    r.levels.deinit(gpa);
    for (r.frames_at.items) |*f| f.deinit(gpa);
    r.frames_at.deinit(gpa);
    r.frames.deinit(gpa);
    r.captures.deinit(gpa);
    r.stacks.deinit(gpa);
    r.obligations.deinit(gpa);
    r.boundary.deinit(gpa);
    r.* = undefined;
}

/// Level `i`'s lists, made the first time a check nests that deep. Its
/// tree comes out cleared.
pub fn level(r: *Retained, gpa: Allocator, i: u32) Allocator.Error!*Level {
    while (r.levels.items.len <= i) {
        try r.levels.ensureUnusedCapacity(gpa, 1);
        const l = try gpa.create(Level);
        l.* = .{};
        r.levels.appendAssumeCapacity(l);
    }
    const l = r.levels.items[i];
    l.tree.nodes.clearRetainingCapacity();
    l.tree.extra.clearRetainingCapacity();
    l.tree.binders.clearRetainingCapacity();
    l.tree.annotated.clearRetainingCapacity();
    l.tree.root = .none;
    return l;
}

/// The lists of a frame at `depth`, moved out, empty.
pub fn takeFrame(r: *Retained, depth: usize) FrameLists {
    if (depth >= r.frames_at.items.len) return .{};
    const lists = r.frames_at.items[depth];
    r.frames_at.items[depth] = .{};
    return lists;
}

/// A popped frame's lists back to `depth`, cleared. Kept when the slot can
/// take them; otherwise freed, which costs only the next frame there an
/// allocation.
pub fn giveFrame(r: *Retained, gpa: Allocator, depth: usize, lists: FrameLists) void {
    var back = lists;
    back.pool.clearRetainingCapacity();
    back.tries.clearRetainingCapacity();
    while (r.frames_at.items.len <= depth) {
        r.frames_at.append(gpa, .{}) catch return back.deinit(gpa);
    }
    const slot = &r.frames_at.items[depth];
    if (slot.pool.capacity != 0 or slot.tries.capacity != 0) return back.deinit(gpa);
    slot.* = back;
}

test "a frame's lists come back cleared and are lent again at their depth" {
    const gpa = std.testing.allocator;
    var r: Retained = .{};
    defer r.deinit(gpa);
    var lists = r.takeFrame(2);
    try lists.pool.append(gpa, @enumFromInt(7));
    const buffer = lists.pool.items.ptr;
    r.giveFrame(gpa, 2, lists);
    const again = r.takeFrame(2);
    try std.testing.expectEqual(@as(usize, 0), again.pool.items.len);
    try std.testing.expectEqual(buffer, again.pool.items.ptr);
    // Out on loan, the slot is empty: a second taker gets lists of its own.
    const other = r.takeFrame(2);
    try std.testing.expectEqual(@as(usize, 0), other.pool.capacity);
    r.giveFrame(gpa, 2, again);
    r.giveFrame(gpa, 2, other);
}
