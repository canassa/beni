//! Free checked identity parameters of a grouped markup body. A nested
//! grouped root needs its packet constructor's parameters here; its own
//! body keeps a separate capture. No runtime value or type text is inspected.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Allocator = std.mem.Allocator;
const Param = Dispatch.Term.Param;

pub const Capture = struct {
    inst: u32,
    grouped: bool = false,
    packet: []const Param = &.{},
    body: []const Param = &.{},
};
pub const Result = struct { params: []const Param, supported: bool };

pub const Collector = struct {
    arena: Allocator,
    bir: *const Bir,
    dispatch: *const Dispatch,
    inst_epoch: []u32,
    term_epoch: []u32,
    epoch: u32 = 0,
    insts: std.ArrayList(Bir.Inst.Index) = .empty,
    terms: std.ArrayList(Dispatch.TermIndex) = .empty,
    candidates: std.ArrayList(Param) = .empty,

    pub fn init(arena: Allocator, bir: *const Bir, dispatch: *const Dispatch) Allocator.Error!Collector {
        const inst_epoch = try arena.alloc(u32, bir.insts.len);
        @memset(inst_epoch, 0);
        const term_epoch = try arena.alloc(u32, dispatch.terms.len);
        @memset(term_epoch, 0);
        return .{ .arena = arena, .bir = bir, .dispatch = dispatch, .inst_epoch = inst_epoch, .term_epoch = term_epoch };
    }

    fn reset(c: *Collector) void {
        c.epoch += 1;
        c.insts.clearRetainingCapacity();
        c.terms.clearRetainingCapacity();
        c.candidates.clearRetainingCapacity();
    }

    /// Parameters needed to form the type identity of a root's own packet.
    pub fn packet(c: *Collector, roots: []const Dispatch.TermIndex, decl: u32) Allocator.Error!Result {
        c.reset();
        try c.terms.appendSlice(c.arena, roots);
        return c.finish(decl);
    }

    /// Parameters read by ordinary calls, and by constructors of nested
    /// packets, when the root's body is evaluated in its hoisted patch.
    pub fn body(c: *Collector, inst: Bir.Inst.Index, moved: []const Bir.Inst.Index, decl: u32, captures: []const Capture) Allocator.Error!Result {
        c.reset();
        try c.insts.append(c.arena, inst);
        try c.insts.appendSlice(c.arena, moved);
        while (c.insts.pop()) |at| {
            if (c.inst_epoch[at.int()] == c.epoch) continue;
            c.inst_epoch[at.int()] = c.epoch;
            if (at != inst and c.bir.instTag(at) == .markup) {
                if (findCapture(captures, at.int())) |nested| if (nested.grouped) {
                    try c.candidates.appendSlice(c.arena, nested.packet);
                    try c.candidates.appendSlice(c.arena, nested.body);
                    continue;
                };
            }
            if (c.dispatch.siteOf(at)) |site| {
                try c.terms.appendSlice(c.arena, c.dispatch.argsAt(site.evidence));
                if (site.callee.unwrap()) |callee| try c.terms.append(c.arena, callee);
            }
            try @import("../check/constrain/Decl.zig").pushChildren(c.bir, c.arena, at, &c.insts);
        }
        return c.finish(decl);
    }

    fn finish(c: *Collector, decl: u32) Allocator.Error!Result {
        while (c.terms.pop()) |term| {
            if (c.term_epoch[term.int()] == c.epoch) continue;
            c.term_epoch[term.int()] = c.epoch;
            const node = c.dispatch.term(term);
            if (node == .param) try c.candidates.append(c.arena, node.param);
            try c.terms.appendSlice(c.arena, c.dispatch.argsOfTerm(term));
        }
        std.mem.sort(Param, c.candidates.items, {}, less);
        var count: usize = 0;
        var supported = true;
        var previous: ?Param = null;
        for (c.candidates.items) |parameter| {
            if (previous) |p| if (std.meta.eql(p, parameter)) continue;
            previous = parameter;
            const slots = switch (parameter.binder) {
                .derived => {
                    supported = false;
                    continue;
                },
                .decl => c.dispatch.declIdentities(decl),
                .let => |at| blk: {
                    // A function made inside the patch binds its own
                    // identities there. Only free binders need capture.
                    if (c.inst_epoch[at.int()] == c.epoch) continue;
                    const row = c.dispatch.letIndex(at) orelse {
                        supported = false;
                        continue;
                    };
                    break :blk c.dispatch.letIdentities(row);
                },
            };
            const methods: usize = switch (parameter.binder) {
                .derived => unreachable,
                .decl => c.dispatch.declRequirements(decl).len,
                .let => |at| c.dispatch.letRequirements(c.dispatch.letIndex(at).?).len,
            };
            // Method dictionaries and checked-data witnesses retain the
            // pre-existing grouping restriction. Only identity Strings
            // may become synthetic inputs under interface 1.26.
            if (parameter.k < methods or parameter.k - methods >= slots.len or
                slots[parameter.k - methods] & Dispatch.checked_evidence != 0)
            {
                supported = false;
                continue;
            }
            c.candidates.items[count] = parameter;
            count += 1;
        }
        return .{ .params = try c.arena.dupe(Param, c.candidates.items[0..count]), .supported = supported };
    }
};

fn binder(p: Param) u64 {
    return switch (p.binder) {
        .decl => 0,
        .let => |at| @as(u64, at.int()) + 1,
        .derived => |index| (@as(u64, 1) << 32) + index,
    };
}
fn less(_: void, a: Param, b: Param) bool {
    return if (binder(a) != binder(b)) binder(a) < binder(b) else a.k < b.k;
}
fn findCapture(captures: []const Capture, inst: u32) ?Capture {
    var lo: usize = 0;
    var hi = captures.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (captures[mid].inst < inst) lo = mid + 1 else hi = mid;
    }
    return if (lo < captures.len and captures[lo].inst == inst) captures[lo] else null;
}
