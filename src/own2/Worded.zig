//! L4: a module's worded contracts by declaration and places
//! (`docs/design/ownership-v2.md` §4.1, *A module table's entries*;
//! #1714). A worded callee's contract is a function of its declaration and
//! the places of a use, so the calls of one callee over the same places
//! read one contract and share its footprint (§2.7): their uses at one path
//! are one liveness group, not one a call. Each entry's fill is paid by
//! every account on its own first read.
//!
//! Obligations kept here: none of §2.14's (a table only).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Runs = @import("Runs.zig");
const Contract = @import("Contract.zig");

pub const Error = Ids.ChargeError;

pub const Worded = struct {
    /// Entries by the run `(module, declaration, result, params…)`.
    runs: Runs.Runs = .{},
    of: Ids.FixedDict(1) = .{},
    cost: Ids.Costs = .{},

    pub fn deinit(w: *Worded, gpa: Allocator) void {
        w.runs.deinit(gpa);
        w.of.deinit(gpa);
        w.cost.deinit(gpa);
    }

    /// The entry of `head` and `params`: its run, and its contract when
    /// made (read here, on `account`).
    pub fn find(w: *Worded, gpa: Allocator, account: *Ids.Account, head: [3]u32, params: []const Ids.PlaceId) Error!struct { run: u32, contract: ?Contract.Id } {
        var key: std.ArrayList(u32) = .empty;
        defer key.deinit(gpa);
        try key.appendSlice(gpa, &head);
        for (params) |at| try key.append(gpa, @backingInt(at));
        const run = try w.runs.intern(gpa, key.items);
        const c = w.of.get(.{run}) orelse return .{ .run = run, .contract = null };
        try account.readEntry(gpa, .worded, run, w.cost.get(run));
        return .{ .run = run, .contract = c };
    }

    /// Entry `run`'s contract `c`, made at a fill of `cost`, read on `account`.
    pub fn put(w: *Worded, gpa: Allocator, account: *Ids.Account, run: u32, c: Contract.Id, cost: u64) Error!void {
        try w.cost.put(gpa, run, cost);
        try w.of.put(gpa, .{run}, c);
        try account.readEntry(gpa, .worded, run, cost);
    }
};
