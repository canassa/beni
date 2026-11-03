//! L10: a demand's twins (`docs/design/ownership-v2.md` §2.8, *Twin
//! demands*): two demands of one evaluation that differ only in the path
//! their text names are one judgement. A callee's writes through a folding
//! `⟲` (`[*]#B.j⟲` for each field `j` of `type B = B (List B) …`) project
//! onto one set of the caller's slots, so the call makes one demand per
//! write with the same targets; the later ones take the first's verdict.
//!
//! Obligations kept here: none of §2.14's directly (a twin is judged by
//! its first: every field the judgement reads is equal).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Walk = @import("Walk.zig");

const Demand = Walk.Demand;
const W = Walk.Walk;
const none: u32 = Ids.none_int;

/// For each demand, the earlier demand it is a twin of (`none`: none).
/// Twins are looked for among the demands one call makes for one
/// argument: a call that makes one for an argument asks nothing (its
/// count is one dictionary step a demand, as the jobs' list is).
pub fn of(gpa: Allocator, account: *Ids.Account, arena: Allocator, w: *const W, ds: []const Demand) Ids.ChargeError![]u32 {
    const out = try arena.alloc(u32, ds.len);
    @memset(out, none);
    var per: Ids.FixedDict(2) = .{};
    defer per.deinit(gpa);
    for (ds) |d| if (d.call != none) {
        const got = try per.getOrPut(gpa, .{ d.call, d.arg });
        got.value_ptr.* = if (got.found_existing) got.value_ptr.* + 1 else 1;
    };
    var index: Ids.FixedDict(2) = .{};
    defer index.deinit(gpa);
    for (ds, 0..) |d, k| {
        if (d.call == none or per.get(.{ d.call, d.arg }).? < 2) continue;
        try account.reserve(.inspection, 1 + d.targets.len);
        const h = hash(w, d);
        const got = try index.getOrPut(gpa, .{ @truncate(h), @truncate(h >> 32) });
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(k);
            continue;
        }
        // A hash hit is compared whole, its operands too.
        try account.reserve(.inspection, 1 + d.targets.len + d.operands.len);
        if (same(w, ds[got.value_ptr.*], d)) out[k] = got.value_ptr.*;
    }
    return out;
}

/// Each twin's line its first's, with its own demand (its own text).
pub fn copy(lines: anytype, twins: []const u32, ds: []const Demand) void {
    for (twins, lines, ds) |tw, *l, d| if (tw != none) {
        l.* = lines[tw];
        l.demand = d;
    };
}

fn hash(w: *const W, d: Demand) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&[_]u32{ d.point, d.base_inst, d.base_local, d.call, d.arg }));
    h.update(std.mem.sliceAsBytes(w.leavesOfRun(d.targets)));
    return h.final();
}

/// Every field a judgement reads equal: all but the text's path (its root
/// and its steps; the targets and operands by their contents, the relied
/// condition by the call and argument it is made from).
fn same(w: *const W, a: Demand, b: Demand) bool {
    if (!std.mem.eql(u32, w.leavesOfRun(a.targets), w.leavesOfRun(b.targets))) return false;
    if (!std.mem.eql(u32, w.valuesOfRun(a.operands), w.valuesOfRun(b.operands))) return false;
    var x = a;
    var y = b;
    inline for (.{ &x, &y }) |p| {
        p.write_path, p.write_rel = .{ .none, 0 };
        p.targets = .{};
        p.operands = .{};
        p.relies = .{};
    }
    return std.meta.eql(x, y);
}
