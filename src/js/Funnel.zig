//! The funnel (`backend.md` §9, *The funnel, and why reuse is honest*): the
//! one place every fact about the build that a unit's bytes depend on is
//! read, and the record of the questions each unit asked.
//!
//! Lowering asks `Lowerer.ask` at every such read — the six survivor sets,
//! the dead arms, the program hook's `consumed`/`wanted`, whether a nullary
//! constant is built, the comparator flags, the runtime exports, and the
//! cross-module import asks. In every build the funnel ANSWERS from the
//! build's own state, so the emitted bytes are what they always were. When
//! `Recorder.record` is set — the pack maker (`core_pack_main.zig`) and
//! nothing else — each answer is also recorded, in the open unit's range.
//!
//! **One flat array and per-unit ranges, no nesting of open units.** Unit
//! boundaries are drawn where the lowering draws them (`Lowerer.recBegin` /
//! `recEnd`), and the derived-arrow build closes its own unit before the
//! `$$steps` build opens its own, so the facts of one unit are always one
//! contiguous run — a record is a few words per unit, and comparing a
//! build's answers to a row's is a walk of the run (`backend.md` §9,
//! *The maker*).
//!
//! **A module is a graph index in here, and a slot in a row.** The recorder
//! knows the build's graph, so a fact or an ask stores the module's
//! `Graph.Index`; the maker maps it to the row's convention — 0 this
//! module, `k + 1` the module-table slot of `modules[k]` — while encoding.
//!
//! **Prep-time asks are recorded too, and belong to no unit.** The walk
//! that decides which declarations survive, `findDeadArms`, and the other
//! passes ask before the first `recBegin`; their answers reach units through
//! the per-unit questions (`.arm_dead`, the selectors, `.direct`,
//! `.markup`), and the asks themselves enter no row, so a build that would
//! answer one differently is a unit that falls back, never a refusal. The
//! maker refuses only machinery whose reads are not all in the funnel — a
//! markup site, a program constructor or a placement, a schema declaration
//! (`core_pack_main.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const EmitPack = @import("EmitPack.zig");
const InternPool = @import("../InternPool.zig");

/// The row's questions and selectors, which the funnel answers and records.
pub const Fact = EmitPack.Fact;
pub const Selector = EmitPack.Selector;

/// The runtime exports a unit reaches, bit for bit with `EmitPack`.
pub const runtime_deep = EmitPack.runtime_deep;
pub const runtime_list_eq = EmitPack.runtime_list_eq;
pub const runtime_list_compare = EmitPack.runtime_list_compare;

/// A record index that is not a record: what a unit of a build with no
/// recorder carries.
pub const no_record = std.math.maxInt(u32);

/// One cross-module name a unit imported (`Lowerer.needName`), before the
/// row's encoding: `Lower.Needed` with the module as a graph index and the
/// two forms `needName` has — an interface value, or a synthesised base's
/// text. What `EmitPack.Needed` is after the maker maps the module.
pub const Ask = struct {
    module: u32,
    value: u32 = EmitPack.no_value,
    base: InternPool.Symbol.Optional = .none,
};

/// What one unit asked (`backend.md` §9, *What a unit carries*): its
/// selector, the run of facts it read, the run of imports it asked for, the
/// runtime exports it reached, and — for a declaration's unit — the edges a
/// join's walk replays.
pub const UnitRecord = struct {
    selector: Selector,
    /// The facts this unit asked: a range of `Recorder.facts`. Asks made
    /// outside any open unit (the passes before the first `recBegin`) are
    /// no unit's.
    facts_start: u32,
    facts_end: u32 = 0,
    /// The import asks: a range of `Recorder.asks`, in ask order, repeats
    /// and all — `needName` dedupes the module's list, not the record.
    asks_start: u32,
    asks_end: u32 = 0,
    /// The runtime exports the unit reached, OR'd at each use
    /// (`EmitPack.runtime_*`), never inferred from the module's flags: a
    /// unit must carry its own, or a join that takes it would drop the
    /// import its code calls.
    runtime: u8 = 0,
    /// The module's outgoing edges this unit's declaration walks, in walk
    /// order (`Lowerer.declEdges`), as canonical positions: `emissionOrder`
    /// filters `refs` to `top_value` and follows every site top, cone
    /// per unit, because one declaration's statements are several units and
    /// each can be taken alone. Empty for a unit that is not a
    /// declaration's.
    edges: []const u32 = &.{},

    pub fn facts(u: *const UnitRecord, r: *const Recorder) []const Fact {
        return r.facts.items[u.facts_start..u.facts_end];
    }

    pub fn asks(u: *const UnitRecord, r: *const Recorder) []const Ask {
        return r.asks.items[u.asks_start..u.asks_end];
    }
};

/// One lowering's record, owned by the caller that set `Input.record`.
pub const Recorder = struct {
    /// Every fact ask, in ask order; the unit records index into it. Its
    /// capacity is reserved once (`reserve`) and never grown again, so an
    /// ask is infallible and a record's range cannot move.
    facts: std.ArrayListUnmanaged(Fact) = .empty,
    asks: std.ArrayListUnmanaged(Ask) = .empty,
    units: std.ArrayListUnmanaged(UnitRecord) = .empty,
    /// Whether a unit is open: `recBegin` without its `recEnd`. One at a
    /// time; the reset of a build's units are drawn by closing one before
    /// opening the next, never by nesting.
    open: bool = false,
    /// Set when an ask found the reserved capacity full. The maker fails
    /// on it rather than caching a partial record (`reserve`'s bound names
    /// the assumption).
    overflow: bool = false,

    pub const Error = error{UnitRecordOverflow};

    /// The capacity every ask of this module needs, allocated once so that
    /// `ask` and `askNeed` never fail and never move the arrays under a
    /// record's range.
    ///
    /// The bound is per instruction, with room to spare: every ask is made
    /// while building the statements of one instruction (a case's arm, a
    /// value's use, a piece), no instruction is built twice except a
    /// declaration the `wanted` loop rebuilds, and the classic walk asks
    /// once per declaration. It is not a proof, so a module that exceeds it
    /// sets `overflow` and the maker fails, naming the module, rather than
    /// caching a record with a hole in it — a defect to fix here, not a
    /// state to ship.
    pub fn reserve(r: *Recorder, scratch: Allocator, insts: usize) Allocator.Error!void {
        try r.facts.ensureTotalCapacity(scratch, 8 * insts + 64);
        try r.asks.ensureTotalCapacity(scratch, 2 * insts + 64);
    }

    /// Opens a unit: the asks from here to `end` are its own.
    pub fn begin(r: *Recorder, scratch: Allocator, selector: Selector) Allocator.Error!u32 {
        std.debug.assert(!r.open);
        const i: u32 = @intCast(r.units.items.len);
        try r.units.append(scratch, .{
            .selector = selector,
            .facts_start = @intCast(r.facts.items.len),
            .asks_start = @intCast(r.asks.items.len),
        });
        r.open = true;
        return i;
    }

    /// Closes the unit `record` (always the last one opened), which the
    /// caller then fills with its edges.
    pub fn end(r: *Recorder, record: u32) Error!void {
        std.debug.assert(r.open and record == r.units.items.len - 1);
        r.open = false;
        if (r.overflow) return error.UnitRecordOverflow;
        const u = &r.units.items[record];
        u.facts_end = @intCast(r.facts.items.len);
        u.asks_end = @intCast(r.asks.items.len);
    }

    /// One answered question, in the open unit's range or — before the
    /// first unit — in no unit's, when the passes ask it.
    pub fn ask(r: *Recorder, fact: Fact) void {
        if (r.facts.items.len == r.facts.capacity) {
            r.overflow = true;
            return;
        }
        r.facts.appendAssumeCapacity(fact);
    }

    /// One import ask (`Lowerer.needName`), at the call and not at the
    /// deduplicated list: a unit's record must hold every name its text
    /// reads even when another unit asked for it first.
    pub fn askNeed(r: *Recorder, entry: Ask) void {
        if (r.asks.items.len == r.asks.capacity) {
            r.overflow = true;
            return;
        }
        r.asks.appendAssumeCapacity(entry);
    }

    /// One runtime export the open unit reached.
    pub fn orRuntime(r: *Recorder, bit: u8) void {
        if (!r.open) return;
        r.units.items[r.units.items.len - 1].runtime |= bit;
    }
};

test "a unit's record is its own run of asks, and a prep ask is no unit's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var r: Recorder = .{};
    try r.reserve(scratch, 8);
    // The passes ask before the first unit: recorded, and no unit's.
    r.ask(.{ .question = .development, .answer = true });

    const one = try r.begin(scratch, .{ .kind = .decl, .a = 3, .b = Selector.direct });
    r.ask(.{ .question = .decl, .answer = true, .index = 3 });
    r.askNeed(.{ .module = 7, .value = 1 });
    r.orRuntime(runtime_deep);
    try r.end(one);

    // A later unit asking the same question with another answer keeps its
    // own range: a reader compares the two units apart.
    const two = try r.begin(scratch, .{ .kind = .nullary, .a = 0, .b = 9 });
    r.ask(.{ .question = .nullary, .answer = false, .index = 9 });
    r.askNeed(.{ .module = 7, .value = 1 });
    try r.end(two);

    try std.testing.expectEqual(@as(usize, 2), r.units.items.len);
    const first = &r.units.items[0];
    try std.testing.expectEqual(@as(usize, 1), first.facts(&r).len);
    try std.testing.expectEqual(Fact.Question.decl, first.facts(&r)[0].question);
    try std.testing.expectEqual(@as(usize, 1), first.asks(&r).len);
    try std.testing.expectEqual(@as(u8, runtime_deep), first.runtime);
    const second = &r.units.items[1];
    try std.testing.expectEqual(@as(usize, 1), second.facts(&r).len);
    try std.testing.expectEqual(Fact.Question.nullary, second.facts(&r)[0].question);
    try std.testing.expectEqual(@as(usize, 1), second.asks(&r).len);
    try std.testing.expectEqual(@as(u8, 0), second.runtime);
    // The prep ask is in neither range, and the second unit's start is the
    // first unit's end: the ranges tile the run.
    try std.testing.expectEqual(@as(usize, 3), r.facts.items.len);
    try std.testing.expectEqual(@as(u32, 1), first.facts_start);
    try std.testing.expectEqual(@as(u32, 2), first.facts_end);
    try std.testing.expectEqual(@as(u32, 2), second.facts_start);
    try std.testing.expectEqual(@as(u32, 3), second.facts_end);
}

test "an ask past the reserve fails the unit that closes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var r: Recorder = .{};
    try r.reserve(scratch, 1);
    const one = try r.begin(scratch, .{ .kind = .decl });
    // One more ask than `reserve`'s bound for these instructions; the
    // maker fails on the error, so a partial record is never written.
    var i: usize = 0;
    while (i < r.facts.capacity + 1) : (i += 1) r.ask(.{ .question = .development, .answer = true });
    try std.testing.expect(r.overflow);
    try std.testing.expectError(error.UnitRecordOverflow, r.end(one));
}
