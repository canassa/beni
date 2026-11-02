//! EXPERIMENT (`--ownership-slots=N`, hidden; ownership-v2.md §8 Q8): a
//! first-order typed-BIR slot evaluator, the local value domain of Astra's
//! second review (§2, §6). It replaces v2's local analysis for the modules it
//! is run on, and reads none of v2's value machinery (`Shape`, `KappaRead`,
//! `Propagate`: `ReaderProbe` counts their calls). What it reuses: the typed
//! BIR, the place graph and its canonical paths (`Place`), the callee and
//! place adapters of `Groups.Module`, the declaration groups of `Prepass`,
//! and the one account (`Ids.Account`), charged for every record below.
//!
//! **The domain.**
//! - *Slots* are the canonical paths of a value's place (`Place.extend`): a
//!   finite vocabulary fixed by the types. A recursive slot (`⟲`) names a
//!   family of occurrences, never one object.
//! - *Positions* are the source's own projections: a pattern's or a field's
//!   concrete path from a *root* (a parameter, or one call site's result).
//!   Two names bound to one projection share its identity.
//! - A *leaf* is "the objects at these object slots, within the subtree of
//!   this position of this root" (shallow storage and payloads are separate
//!   slots), or a fresh allocation (a literal's site, or a call's own fresh
//!   objects), or `⊤`. Unknown provenance is `⊤`, never empty.
//! - *Separation* `Sep(R)`: every object occurs at most once among root R's
//!   positions. For a parameter it is an assumption the callers owe; for a
//!   call it is the callee's `res_cond` instantiated on the arguments.
//!   Two disjoint positions of one root are apart under `Sep(root)`; that is
//!   what lets a writer edit one payload beside the rest of the tree.
//! - *Non-duplication* is `Sep` of a built value: its components, each
//!   separated, pairwise apart (coexisting parts add, saturating at
//!   repeated); an alternative's arms each (the maximum). Reads observe.
//! - *Calls* are instantiated once per call site: per result slot, the
//!   callee's arrivals projected onto the arguments (`inst`), and its
//!   `res_cond` on them (`instCond`). One allocation is one identity.
//! - *Choices*: a `case`'s value is an alternative tagged by its choice;
//!   projections keep the tag, so two values of one choice are compared arm
//!   by arm (`if c then (p, []) else ([], p)` keeps its parts apart), two
//!   choices never.
//! - An empty recursive result is ⊥ (strict in constructions and calls).
//!
//! **Contracts** (one per declaration, inferred in this same domain; a
//! recursive group's by a fixed point from ⊥, then validated by a separate
//! evaluation of each body under the final candidate): per object slot of
//! the result its arrivals (parameter slots, fresh, `⊤`), `res_cond`, the
//! parameter slots written (`writes`) and the conditions on the parameters
//! the writes rely on (`req`). Contracts of other modules come back from a
//! canonical word encoding (`exported`): ctor steps as `(ordinal, arg)`.
//!
//! **Out of scope, reported explicitly** (`unsupported …`, never routed to
//! v2): lambdas, local functions, function-typed values, record update,
//! `try`, markup, callees with no contract or words.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Ast = @import("../parse/Ast.zig");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Groups = @import("Groups.zig");
const Facts = @import("Facts.zig");
const Prepass = @import("Prepass.zig");
const Message = @import("Message.zig");
const Hoists = @import("Hoists.zig");
const ReaderProbe = @import("ReaderProbe.zig");

const PathId = Ids.PathId;
const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Error = Ids.ChargeError;
const none: u32 = std.math.maxInt(u32);
const tuple_key: u32 = 0xFFFF_FF00;

pub const Mode = enum(u8) {
    /// Inference and validation.
    infer = 1,
    /// A false-contract control: every declaration's candidate claims full
    /// non-duplication; the validator alone must refuse a false claim.
    forced = 2,
    /// The forced-unsafe control: the forced claim is published whatever the
    /// validator says (the runtime observer must catch it).
    unsafe = 3,
    /// Copy semantics: every write refused (no write is published).
    copy = 4,
};

// ===========================================================================
// Conditions
// ===========================================================================

/// A conjunction about the declaration's own parameters. `sel` is the set
/// of *selected occurrences*, each `(param << 32) | steps id` (a canonical
/// slot of that parameter): every object at one of them occurs once among
/// all of them — `Sep` restricted to the selection, the inductive predicate
/// of a region (review §2). A conjunction is the union: linear, never a
/// table of pairs. `ok == false` is unprovable.
const Cond = struct {
    ok: bool = true,
    sel: []const u64 = &.{},
    /// Every object of every parameter (the forced controls' claim).
    all: bool = false,

    const yes: Cond = .{};
    const no: Cond = .{ .ok = false };

    fn conj(a: Cond, b: Cond) Cond {
        if (!a.ok or !b.ok) return .no;
        return .{ .ok = true, .sel = mergeIds(a.sel, b.sel), .all = a.all or b.all };
    }
    fn eql(a: Cond, b: Cond) bool {
        return a.ok == b.ok and a.all == b.all and std.mem.eql(u64, a.sel, b.sel);
    }
    /// `a` asks no more than `b` (b ⇒ a).
    fn weaker(a: Cond, b: Cond) bool {
        if (!b.ok) return true;
        if (!a.ok) return false;
        if (b.all) return true;
        if (a.all) return false;
        for (a.sel) |f| if (std.mem.indexOfScalar(u64, b.sel, f) == null) return false;
        return true;
    }
};

/// The module run in progress on this thread (its arena holds merged
/// selections).
threadlocal var cur_slots: ?*Slots = null;

fn mergeIds(x: []const u64, y: []const u64) []const u64 {
    if (y.len == 0) return x;
    if (x.len == 0) return y;
    if (std.mem.eql(u64, x, y)) return x;
    const a = cur_slots.?.arena;
    const out = a.alloc(u64, x.len + y.len) catch @panic("out of memory");
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < x.len or j < y.len) {
        const v = if (j >= y.len or (i < x.len and x[i] <= y[j])) blk: {
            const v = x[i];
            if (j < y.len and y[j] == v) j += 1;
            i += 1;
            break :blk v;
        } else blk: {
            j += 1;
            break :blk y[j - 1];
        };
        out[n] = v;
        n += 1;
    }
    if (cur_slots.?.cur_account) |acc| acc.reserve(.cond, @intCast(n)) catch {};
    return out[0..n];
}

/// A selection in its canonical order: by parameter, then by the slot's
/// steps (never by intern order, which is discovery order).
fn canonicalSel(s: *Slots, sel: []const u64) Allocator.Error![]u64 {
    const out = try s.arena.dupe(u64, sel);
    std.mem.sort(u64, out, s, struct {
        fn lt(sl: *Slots, x: u64, y: u64) bool {
            if (x >> 32 != y >> 32) return x >> 32 < y >> 32;
            return std.mem.order(u32, sl.steps_tab.items[@as(u32, @truncate(x))], sl.steps_tab.items[@as(u32, @truncate(y))]) == .lt;
        }
    }.lt);
    return out;
}

fn occ(j: u32, sid: u32) u64 {
    return (@as(u64, j) << 32) | sid;
}

/// Steps as an id in the module's table (canonical words, content-keyed).
fn internSteps(s: *Slots, steps: []const u32) Allocator.Error!u32 {
    const bytes = std.mem.sliceAsBytes(steps);
    if (s.steps_index.get(bytes)) |hit| return hit;
    const id: u32 = @intCast(s.steps_tab.items.len);
    const own = try s.arena.dupe(u32, steps);
    try s.steps_tab.append(s.gpa, own);
    try s.steps_index.put(s.gpa, std.mem.sliceAsBytes(own), id);
    return id;
}

const max_params = 16;

/// The overlap of two leaves: certainly not, under a condition, or may.
const Ov = struct {
    yes: bool = false,
    cond: Cond = .{},
    const no: Ov = .{};
    const may: Ov = .{ .yes = true };
    fn join(a: Ov, b: Ov) Ov {
        if (a.yes or b.yes) return may;
        return .{ .cond = a.cond.conj(b.cond) };
    }
};

// ===========================================================================
// Contracts (module-level, in the contract arena)
// ===========================================================================

const ArrKind = enum(u8) { param, fresh, top, shared };
const Arr = struct { kind: ArrKind, j: u32 = 0, steps: []const u32 = &.{} };
const ResSlot = struct { steps: []const u32, var_leaf: bool, arrs: []const Arr };
const WSlot = struct { j: u32, steps: []const u32 };

pub const Contract = struct {
    nparams: u32 = 0,
    /// The result holds no storage at any depth.
    res_cross: bool = false,
    /// Some activation returns (false: ⊥, a recursive candidate's start).
    returns: bool = false,
    res: []const ResSlot = &.{},
    res_cond: Cond = .{},
    writes: []const WSlot = &.{},
    req: Cond = .{},
    unsupported: ?[]const u8 = null,
    /// A word row (core): taken as given, not inferred.
    from_words: bool = false,
    validated: bool = true,
};

fn arrLess(_: void, a: Arr, b: Arr) bool {
    if (a.kind != b.kind) return @backingInt(a.kind) < @backingInt(b.kind);
    if (a.j != b.j) return a.j < b.j;
    return std.mem.order(u32, a.steps, b.steps) == .lt;
}
fn arrEql(a: Arr, b: Arr) bool {
    return a.kind == b.kind and a.j == b.j and std.mem.eql(u32, a.steps, b.steps);
}
fn wLess(_: void, a: WSlot, b: WSlot) bool {
    if (a.j != b.j) return a.j < b.j;
    return std.mem.order(u32, a.steps, b.steps) == .lt;
}

fn contractEql(a: *const Contract, b: *const Contract) bool {
    if (a.returns != b.returns or a.res_cross != b.res_cross or !a.res_cond.eql(b.res_cond) or !a.req.eql(b.req)) return false;
    if (a.res.len != b.res.len or a.writes.len != b.writes.len) return false;
    for (a.res, b.res) |x, y| {
        if (!std.mem.eql(u32, x.steps, y.steps) or x.arrs.len != y.arrs.len) return false;
        for (x.arrs, y.arrs) |p, q| if (!arrEql(p, q)) return false;
    }
    for (a.writes, b.writes) |x, y| if (x.j != y.j or !std.mem.eql(u32, x.steps, y.steps)) return false;
    return true;
}

/// `got` says no more than `claim` (validation).
fn contractWithin(got: *const Contract, claim: *const Contract) bool {
    const r = contractWithin0(got, claim);
    if (!r and dbg) std.debug.print("within fail: returns {} {} rc {} {d} / {} {d} req {} {d} / {} {d} w {d}/{d} res {d}/{d}\n", .{ got.returns, claim.returns, got.res_cond.ok, got.res_cond.sel.len, claim.res_cond.ok, claim.res_cond.sel.len, got.req.ok, got.req.sel.len, claim.req.ok, claim.req.sel.len, got.writes.len, claim.writes.len, got.res.len, claim.res.len });
    return r;
}
const dbg = false;
fn contractWithin0(got: *const Contract, claim: *const Contract) bool {
    if (got.returns and !claim.returns) return false;
    if (claim.res_cond.ok and !got.res_cond.weaker(claim.res_cond)) return false;
    if (!got.req.weaker(claim.req)) return false;
    for (got.writes) |w| {
        const found = for (claim.writes) |c| {
            if (c.j == w.j and std.mem.eql(u32, c.steps, w.steps)) break true;
        } else false;
        if (!found) return false;
    }
    for (got.res) |r| {
        const cr = for (claim.res) |c| {
            if (std.mem.eql(u32, c.steps, r.steps)) break c;
        } else {
            if (r.arrs.len != 0) return false;
            continue;
        };
        for (r.arrs) |x| {
            const found = for (cr.arrs) |y| {
                if (arrEql(x, y)) break true;
            } else false;
            if (!found) return false;
        }
    }
    return true;
}

// ===========================================================================
// The exported contracts (the minimal canonical round-trip)
// ===========================================================================

var exported_lock: std.atomic.Value(bool) = .init(false);
fn lockExported() void {
    while (exported_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn unlockExported() void {
    exported_lock.store(false, .release);
}
var exported: std.AutoHashMapUnmanaged([2]u32, []const u32) = .empty;

/// Step words as canonical words: a constructor step as `(kind, ordinal,
/// arg)`, any other as `(kind, payload, 0)`. A field step is not encoded
/// (its rank is module-local): the export says so.
fn encodeSteps(places: *const Place.Table, steps: []const u32, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!bool {
    try out.append(gpa, @intCast(steps.len));
    for (steps) |w| {
        const s = Step.fromWord(w);
        switch (s.kind) {
            .ctor_arg => {
                const ca = places.ctorArgOf(s);
                try out.appendSlice(gpa, &.{ @backingInt(s.kind), ca[0], ca[1] });
            },
            .field => return false,
            else => try out.appendSlice(gpa, &.{ @backingInt(s.kind), s.payload, 0 }),
        }
    }
    return true;
}

fn encodeContract(places: *const Place.Table, c: *const Contract, gpa: Allocator) Allocator.Error!?[]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x534c4f54, c.nparams, @intFromBool(c.res_cross), @intFromBool(c.returns) });
    for ([_]Cond{ c.res_cond, c.req }) |cd| {
        try out.appendSlice(gpa, &.{ @intFromBool(cd.ok) | (@as(u32, @intFromBool(cd.all)) << 1), @intCast(cd.sel.len) });
        for (try canonicalSel(cur_slots.?, cd.sel)) |o| {
            try out.append(gpa, @intCast(o >> 32));
            if (!try encodeSteps(places, cur_slots.?.steps_tab.items[@as(u32, @truncate(o))], &out, gpa)) {
                out.deinit(gpa);
                return null;
            }
        }
    }
    try out.append(gpa, @intCast(c.res.len));
    for (c.res) |r| {
        if (!try encodeSteps(places, r.steps, &out, gpa)) {
            out.deinit(gpa);
            return null;
        }
        try out.appendSlice(gpa, &.{ @intFromBool(r.var_leaf), @intCast(r.arrs.len) });
        for (r.arrs) |a| {
            try out.appendSlice(gpa, &.{ @backingInt(a.kind), a.j });
            if (!try encodeSteps(places, a.steps, &out, gpa)) {
                out.deinit(gpa);
                return null;
            }
        }
    }
    try out.append(gpa, @intCast(c.writes.len));
    for (c.writes) |w| {
        try out.append(gpa, w.j);
        if (!try encodeSteps(places, w.steps, &out, gpa)) {
            out.deinit(gpa);
            return null;
        }
    }
    return try out.toOwnedSlice(gpa);
}

const Decoder = struct {
    words: []const u32,
    at: usize = 0,
    places: *Place.Table,
    gpa: Allocator,
    arena: Allocator,
    account: *Ids.Account,
    fn next(d: *Decoder) !u32 {
        if (d.at >= d.words.len) return error.BadContract;
        d.at += 1;
        return d.words[d.at - 1];
    }
    fn steps(d: *Decoder) ![]const u32 {
        const n = try d.next();
        const out = try d.arena.alloc(u32, n);
        for (out) |*w| {
            const kind: Place.StepKind = @fromBackingInt(@as(u4, @intCast(try d.next())));
            const a = try d.next();
            const b = try d.next();
            const s: Step = switch (kind) {
                .ctor_arg => try d.places.ctorStep(d.gpa, d.account, a, b),
                else => .{ .kind = kind, .payload = @intCast(a) },
            };
            w.* = s.word();
        }
        return out;
    }
    fn cond(d: *Decoder) !Cond {
        const flags = try d.next();
        const ok = flags & 1 != 0;
        const n = try d.next();
        const sel = try d.arena.alloc(u64, n);
        for (sel) |*o| {
            const j = try d.next();
            o.* = occ(j, try internSteps(cur_slots.?, try d.steps()));
        }
        std.mem.sort(u64, sel, {}, std.sort.asc(u64));
        return .{ .ok = ok, .sel = sel, .all = flags & 2 != 0 };
    }
    fn contract(d: *Decoder) !Contract {
        if (try d.next() != 0x534c4f54) return error.BadContract;
        var c: Contract = .{};
        c.nparams = try d.next();
        c.res_cross = try d.next() != 0;
        c.returns = try d.next() != 0;
        c.res_cond = try d.cond();
        c.req = try d.cond();
        const nr = try d.next();
        const res = try d.arena.alloc(ResSlot, nr);
        for (res) |*r| {
            const st = try d.steps();
            const vl = try d.next() != 0;
            const na = try d.next();
            const arrs = try d.arena.alloc(Arr, na);
            for (arrs) |*a| {
                a.kind = @fromBackingInt(@as(u8, @intCast(try d.next())));
                a.j = try d.next();
                a.steps = try d.steps();
            }
            r.* = .{ .steps = st, .var_leaf = vl, .arrs = arrs };
        }
        c.res = res;
        const nw = try d.next();
        const ws = try d.arena.alloc(WSlot, nw);
        for (ws) |*w| {
            w.j = try d.next();
            w.steps = try d.steps();
        }
        c.writes = ws;
        return c;
    }
};

// ===========================================================================
// The module run
// ===========================================================================

pub const Stats = struct {
    rounds: u32 = 0,
    evaluations: u32 = 0,
    validation_records: u64 = 0,
    slots: u32 = 0,
    arrivals: u32 = 0,
    relation_facts: u64 = 0,
    relation_memo_hits: u64 = 0,
    deliveries: u32 = 0,
    substitutions: u64 = 0,
    positions: u64 = 0,
    leaves: u64 = 0,
    values: u64 = 0,
    calls: u64 = 0,
    demands: u64 = 0,
    peak_bytes: usize = 0,
    v2_reads: u64 = 0,
    /// Records of each evaluation (a body walk), the first sixteen.
    walks: [16]u64 = @splat(0),
};

const DeclState = struct {
    di: u32,
    contract: ?*Contract = null,
    account: Ids.Account = .{},
    stats: Stats = .{},
    lines: std.ArrayList([]const u8) = .empty,
    unsupported: ?[]const u8 = null,
    done: bool = false,
    validated: bool = true,
    note: []const u8 = "",
    channel: std.ArrayList(ChannelRow) = .empty,
};
const ChannelRow = struct { inst: u32, refused: bool, callers: bool };

pub const Slots = struct {
    gpa: Allocator,
    arena: Allocator,
    mod: *Groups.Module,
    in: *const Groups.Input,
    names: Message.Names,
    mode: Mode,
    decls: []?*DeclState,
    /// Closures: per canonical path, the object slots below it (sorted).
    closure_memo: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    below_memo: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    canon_memo: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    steps_memo: std.AutoHashMapUnmanaged(u32, []const u32) = .empty,
    word_memo: std.AutoHashMapUnmanaged([2]u32, *Contract) = .empty,
    import_memo: std.AutoHashMapUnmanaged([2]u32, ?*Contract) = .empty,
    /// The group being solved: decl → its candidate.
    group: std.AutoHashMapUnmanaged(u32, *Contract) = .empty,
    channel: ?*Hoists.Builder = null,
    out: std.ArrayList([]const u8) = .empty,
    imports_read: u32 = 0,
    imports_mismatched: u32 = 0,
    steps_tab: std.ArrayList([]const u32) = .empty,
    steps_index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The account being charged (for a merge's records).
    cur_account: ?*Ids.Account = null,

    fn places(s: *Slots) *Place.Table {
        return &s.mod.places;
    }
};

/// Check module `mod` with the slot evaluator; its report lines appended to
/// `others`. Returns whether every declaration was supported and accepted.
pub fn run(gpa: Allocator, arena: Allocator, in: *const Groups.Input, mod: *Groups.Module, names: Message.Names, channel: ?*Hoists.Builder, others: *std.ArrayList([]const u8)) Allocator.Error!void {
    const mode: Mode = @fromBackingInt(@max(1, @min(4, in.slots & 7)));
    const prepass = try Prepass.run(gpa, mod.prepass_arena.allocator(), .{ .bir = in.bir, .dispatch = in.dispatch });
    var s: Slots = .{ .gpa = gpa, .arena = arena, .mod = mod, .in = in, .names = names, .mode = mode, .decls = try arena.alloc(?*DeclState, in.bir.decls.len), .channel = channel };
    @memset(s.decls, null);
    defer {
        s.closure_memo.deinit(gpa);
        s.below_memo.deinit(gpa);
        s.canon_memo.deinit(gpa);
        s.steps_memo.deinit(gpa);
        s.word_memo.deinit(gpa);
        s.import_memo.deinit(gpa);
        s.group.deinit(gpa);
        s.steps_tab.deinit(gpa);
        s.steps_index.deinit(gpa);
        cur_slots = null;
    }
    cur_slots = &s;
    const reads0 = ReaderProbe.calls.load(.monotonic);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    for (0..prepass.starts.len - 1) |gi| {
        try Groups.groupMembers(gpa, in, &prepass, gi, null, &members);
        if (members.items.len == 0) continue;
        const states = try arena.alloc(DeclState, members.items.len);
        for (states, members.items) |*st, di| {
            st.* = .{ .di = di, .account = .{ .allowance = Groups.allowanceOf(in.bir, di) } };
            st.account.source = in.bir.decls[di].inst_end.int() - in.bir.decls[di].inst_start.int();
            s.decls[di] = st;
        }
        const r0 = ReaderProbe.calls.load(.monotonic);
        solveGroup(&s, states, prepass.recursive[gi]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => for (states) |*st| {
                if (st.unsupported == null) st.unsupported = switch (err) {
                    error.OwnershipLimit => "limit: ownership_summary_size",
                    error.AccountingInvariant => "limit: accounting invariant",
                    error.ProbeLength => "limit: probe_length",
                    else => "limit",
                };
                st.done = true;
            },
        };
        const r1 = ReaderProbe.calls.load(.monotonic);
        for (states) |*st| st.stats.v2_reads = r1 - r0;
        for (states) |*st| try report(&s, st, others);
    }
    const reads1 = ReaderProbe.calls.load(.monotonic);
    try others.append(arena, try std.fmt.allocPrint(arena, "slots module: v2 value-reader calls {d} (process-wide so far {d}), imported contracts {d} (round trip mismatches {d})", .{ reads1 - reads0, reads1, s.imports_read, s.imports_mismatched }));
}

fn declName(s: *Slots, di: u32) []const u8 {
    return s.names.declName(s.in.module, di);
}

fn report(s: *Slots, st: *DeclState, others: *std.ArrayList([]const u8)) Allocator.Error!void {
    const a = s.arena;
    if (s.channel) |ch| {
        if (st.unsupported != null) ch.unchecked = true;
        for (st.channel.items) |r| try ch.add(a, r.inst, .writer, r.refused, r.callers);
    }
    const name = declName(s, st.di);
    for (st.lines.items) |l| try others.append(a, l);
    if (st.unsupported) |why| try others.append(a, try std.fmt.allocPrint(a, "unsupported {s}: {s}", .{ name, why }));
    if (st.contract) |c| {
        var buf: std.Io.Writer.Allocating = .init(a);
        const w = &buf.writer;
        w.print("contract {s}: ", .{name}) catch return error.OutOfMemory;
        if (c.res_cross) w.writeAll("res crossing") catch return error.OutOfMemory else if (!c.returns) w.writeAll("res ⊥") catch return error.OutOfMemory else {
            w.writeAll("res") catch return error.OutOfMemory;
            var first = true;
            for (c.res) |r| {
                if (r.arrs.len == 0) continue;
                w.writeAll(if (first) " " else ", ") catch return error.OutOfMemory;
                first = false;
                try stepsText(s, w, r.steps);
                for (r.arrs) |x| switch (x.kind) {
                    .param => {
                        w.print(" π{d}", .{x.j + 1}) catch return error.OutOfMemory;
                        try stepsText(s, w, x.steps);
                    },
                    .fresh => w.writeAll(" fresh") catch return error.OutOfMemory,
                    .top => w.writeAll(" ⊤") catch return error.OutOfMemory,
                    .shared => w.writeAll(" shared") catch return error.OutOfMemory,
                };
            }
        }
        w.writeAll("; nondup ") catch return error.OutOfMemory;
        try condText(w, c.res_cond);
        if (c.writes.len != 0) {
            w.writeAll("; writes") catch return error.OutOfMemory;
            for (c.writes) |x| {
                w.print(" π{d}", .{x.j + 1}) catch return error.OutOfMemory;
                try stepsText(s, w, x.steps);
            }
            w.writeAll("; req ") catch return error.OutOfMemory;
            try condText(w, c.req);
        }
        if (!st.validated) w.writeAll("; NOT VALIDATED") catch return error.OutOfMemory;
        if (st.note.len != 0) w.print("; {s}", .{st.note}) catch return error.OutOfMemory;
        try others.append(a, buf.written());
    }
    const ac = &st.account;
    const x = &st.stats;
    try others.append(a, try std.fmt.allocPrint(a, "slotacct {s}: source {d}, total {d}, growth {d} of {d}, continuation {d} of {d}, rounds {d}, evaluations {d}, validation {d}, slots {d}, arrivals {d}, relations {d} (memo {d}), deliveries {d}, substitutions {d}, positions {d}, leaves {d}, values {d}, calls {d}, demands {d}, peak bytes {d}, v2 reads {d}, walks {any}", .{ name, ac.source, ac.total(), ac.growth, ac.allowance, ac.continuation, ac.continuationCap(), x.rounds, x.evaluations, x.validation_records, x.slots, x.arrivals, x.relation_facts, x.relation_memo_hits, x.deliveries, x.substitutions, x.positions, x.leaves, x.values, x.calls, x.demands, x.peak_bytes, x.v2_reads, x.walks[0..@min(16, x.evaluations)] }));
}

fn condText(w: *std.Io.Writer, c: Cond) Allocator.Error!void {
    if (!c.ok) return w.writeAll("no") catch error.OutOfMemory;
    if (c.all) return w.writeAll("⇐ all") catch error.OutOfMemory;
    if (c.sel.len == 0) return w.writeAll("yes") catch error.OutOfMemory;
    const s = cur_slots.?;
    w.writeAll("⇐ sel") catch return error.OutOfMemory;
    var last: u32 = none;
    for (try canonicalSel(s, c.sel)) |o| {
        const j: u32 = @intCast(o >> 32);
        if (j != last) {
            if (last != none) w.writeAll("}") catch return error.OutOfMemory;
            w.print(" π{d}{{", .{j + 1}) catch return error.OutOfMemory;
            last = j;
        } else w.writeAll(",") catch return error.OutOfMemory;
        try stepsText(s, w, s.steps_tab.items[@as(u32, @truncate(o))]);
    }
    w.writeAll("}") catch return error.OutOfMemory;
}

fn stepsText(s: *Slots, w: *std.Io.Writer, steps: []const u32) Allocator.Error!void {
    for (steps) |word| {
        const st = Step.fromWord(word);
        (switch (st.kind) {
            .ctor_arg => blk: {
                const ca = s.places().ctorArgOf(st);
                break :blk w.print("#{d}.{d}", .{ ca[0], ca[1] });
            },
            .index => w.print(".{d}", .{st.payload}),
            .field => w.print(".f{d}", .{st.payload}),
            .elem => w.writeAll("[*]"),
            .level => w.writeAll("⟲"),
            .contents => w.writeAll("◆"),
            else => w.writeAll("?"),
        }) catch return error.OutOfMemory;
    }
    if (steps.len == 0) w.writeAll("ε") catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Solving a group
// ---------------------------------------------------------------------------

fn solveGroup(s: *Slots, states: []DeclState, recursive: bool) Error!void {
    const gpa = s.gpa;
    s.group.clearRetainingCapacity();
    if (!recursive) {
        for (states) |*st| {
            const c = try evalDecl(s, st, true);
            st.contract = c;
            if (s.mode != .infer and s.mode != .copy and c.unsupported == null) try forcedClaim(s, st, c);
            st.done = true;
            try publish(s, st);
        }
        return;
    }
    // A recursive group: candidates from ⊥, a fixed point, then a separate
    // validation of each body under the final candidates.
    for (states) |*st| {
        const c = try s.arena.create(Contract);
        c.* = .{ .nparams = s.in.bir.decls[st.di].params };
        if (s.mode == .forced or s.mode == .unsafe) {
            c.res_cond = .{ .ok = true, .all = true };
        }
        st.contract = c;
        try s.group.put(gpa, st.di, c);
    }
    var round: u32 = 0;
    while (true) : (round += 1) {
        var moved = false;
        for (states) |*st| {
            st.stats.rounds += 1;
            const got = try evalDecl(s, st, false);
            if (got.unsupported) |why| {
                st.unsupported = why;
                for (states) |*o| o.done = true;
                return;
            }
            const old = st.contract.?;
            const joined = try joinContract(s, old, got);
            st.stats.deliveries += 1;
            if (!contractEql(joined, old)) {
                moved = true;
                st.contract = joined;
                try s.group.put(gpa, st.di, joined);
            }
        }
        if (!moved) break;
        if (round > 64) {
            for (states) |*st| st.unsupported = "no fixed point in 64 rounds";
            return;
        }
    }
    // Validation: each body once more, against the final candidates; nothing
    // kept from the inference but the candidates themselves.
    for (states) |*st| {
        const before = st.account.total();
        st.lines.clearRetainingCapacity();
        st.channel.clearRetainingCapacity();
        const got = try evalDecl(s, st, true);
        st.stats.validation_records += st.account.total() - before;
        const claim = st.contract.?;
        st.validated = got.unsupported == null and contractWithin(got, claim);
        if (!st.validated) {
            if (s.mode == .unsafe) {
                st.note = "forced claim published unvalidated (unsafe control)";
            } else {
                // The claim is false: publish what the body supports.
                st.note = "candidate refused by the validator; the body's own contract published";
                got.validated = false;
                st.contract = got;
                try s.group.put(gpa, st.di, got);
            }
        }
    }
    if (s.mode != .infer) {
        // Lines under a refused claim were computed against it: once more
        // against what is published.
        var any = false;
        for (states) |*st| any = any or !st.validated;
        if (any and s.mode != .unsafe) for (states) |*st| {
            st.lines.clearRetainingCapacity();
            st.channel.clearRetainingCapacity();
            _ = try evalDecl(s, st, true);
        };
    }
    for (states) |*st| {
        st.done = true;
        try publish(s, st);
    }
}

/// The forced claim of a non-recursive declaration (modes 2, 3): full
/// non-duplication, checked by the body's own evaluation.
fn forcedClaim(s: *Slots, st: *DeclState, c: *Contract) Error!void {
    if (c.res_cond.ok) return;
    if (s.mode == .unsafe) {
        c.res_cond = .{ .ok = true, .all = true };
        st.validated = false;
        st.note = "forced claim published unvalidated (unsafe control)";
    } else {
        st.validated = false;
        st.note = "forced claim refused by the validator";
    }
}

fn publish(s: *Slots, st: *DeclState) Error!void {
    const c = st.contract orelse return;
    if (c.unsupported != null) return;
    const d = s.in.bir.decls[st.di];
    if (!d.is_pub) return;
    const words = (try encodeContract(s.places(), c, s.gpa)) orelse return;
    lockExported();
    defer unlockExported();
    const gop = try exported.getOrPut(std.heap.page_allocator, .{ s.in.module, st.di });
    if (gop.found_existing) std.heap.page_allocator.free(gop.value_ptr.*);
    gop.value_ptr.* = try std.heap.page_allocator.dupe(u32, words);
    s.gpa.free(words);
}

fn joinContract(s: *Slots, a: *const Contract, b: *const Contract) Error!*Contract {
    const out = try s.arena.create(Contract);
    out.* = .{ .nparams = a.nparams, .res_cross = b.res_cross, .returns = a.returns or b.returns };
    out.res_cond = if (!a.returns) b.res_cond else if (!b.returns) a.res_cond else a.res_cond.conj(b.res_cond);
    if (s.mode == .forced or s.mode == .unsafe) out.res_cond = a.res_cond;
    out.req = a.req.conj(b.req);
    // Result slots: the union by steps.
    var res: std.ArrayList(ResSlot) = .empty;
    for (a.res) |r| try res.append(s.arena, r);
    for (b.res) |r| {
        var merged = false;
        for (res.items) |*x| if (std.mem.eql(u32, x.steps, r.steps)) {
            merged = true;
            var arrs: std.ArrayList(Arr) = .empty;
            try arrs.appendSlice(s.arena, x.arrs);
            for (r.arrs) |y| {
                const found = for (arrs.items) |z| {
                    if (arrEql(y, z)) break true;
                } else false;
                if (!found) try arrs.append(s.arena, y);
            }
            std.mem.sort(Arr, arrs.items, {}, arrLess);
            x.arrs = arrs.items;
            break;
        };
        if (!merged) try res.append(s.arena, r);
    }
    std.mem.sort(ResSlot, res.items, {}, struct {
        fn lt(_: void, x: ResSlot, y: ResSlot) bool {
            return std.mem.order(u32, x.steps, y.steps) == .lt;
        }
    }.lt);
    out.res = res.items;
    var ws: std.ArrayList(WSlot) = .empty;
    try ws.appendSlice(s.arena, a.writes);
    for (b.writes) |w| {
        const found = for (ws.items) |x| {
            if (x.j == w.j and std.mem.eql(u32, x.steps, w.steps)) break true;
        } else false;
        if (!found) try ws.append(s.arena, w);
    }
    std.mem.sort(WSlot, ws.items, {}, wLess);
    out.writes = ws.items;
    return out;
}

// ===========================================================================
// One evaluation of a body
// ===========================================================================

const ValKind = enum(u8) { scalar, bot, con, obj, ref, alt, top, shared };
const Val = struct {
    kind: ValKind,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = none,
    kids: Ids.Range = .{},
};

const RootKind = enum(u8) { param, call };
const Root = struct { kind: RootKind, a: u32, place: PlaceId, path: PathId, pos: u32 };

const Call = struct {
    inst: u32,
    contract: *const Contract,
    args: []const u32,
    places: []const PlaceId,
    root: u32,
    cond: ?Cond = null,
    /// Per caller result slot, its leaves: built once at the call site.
    inst_map: std.AutoHashMapUnmanaged(u32, Ids.Range) = .empty,
};

const PKind = enum(u8) { plain, front, back, slice };
const PStep = struct { kind: PKind, a: u32 = 0, b: u32 = 0 };
const Pos = struct { parent: u32, step: PStep, root: u32, slot: PathId, depth: u32 };

const LeafKind = enum(u8) { ref, site, callfresh, shared, top };
const Leaf = struct {
    kind: LeafKind,
    root: u32 = 0,
    pos: u32 = 0,
    /// A slot set: the object slots this leaf covers (ref).
    slots: u32 = 0,
    tags: u32 = 0,
    /// A shallow target exactly at its position's own slot (a storage
    /// write of the position itself).
    at_pos: bool = false,
};

const Ctx = struct { parent: u32, case: u32, arm: u32, depth: u32 };
const Use = struct { local: u32, point: u32, ctx: u32, token: u32 };

const Demand = struct {
    inst: u32,
    point: u32,
    ctx: u32,
    pending: []const u32,
    /// The written slots' targets, one entry per written (param, steps).
    targets: []const Target,
    req: Cond,
    req_why: []const u8 = "",
    op: []const u8,
    primitive: bool,
};
const Target = struct { j: u32, steps: []const u32, leaves: []const u32, arg_inst: u32 };

const Body = struct {
    s: *Slots,
    st: *DeclState,
    arena_state: std.heap.ArenaAllocator,
    arena: Allocator,
    /// The evaluation whose lines are the declaration's (not an inference round).
    final: bool,
    d: Bir.Decl,
    locals_start: u32,
    vals: std.ArrayList(Val) = .empty,
    kids: std.ArrayList(u32) = .empty,
    roots: std.ArrayList(Root) = .empty,
    calls: std.ArrayList(Call) = .empty,
    pos: std.ArrayList(Pos) = .empty,
    pos_index: std.AutoHashMapUnmanaged([4]u32, u32) = .empty,
    leaves: std.ArrayList(Leaf) = .empty,
    leaf_index: std.AutoHashMapUnmanaged([6]u32, u32) = .empty,
    leaf_lists: std.ArrayList(u32) = .empty,
    sets: std.ArrayList(u32) = .empty,
    set_ranges: std.ArrayList(Ids.Range) = .empty,
    set_index: std.StringHashMapUnmanaged(u32) = .empty,
    tag_ranges: std.ArrayList(Ids.Range) = .empty,
    tag_words: std.ArrayList([2]u32) = .empty,
    tag_index: std.StringHashMapUnmanaged(u32) = .empty,
    locals: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    bound_at: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    local_token: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    uses: std.ArrayList(Use) = .empty,
    ctxs: std.ArrayList(Ctx) = .empty,
    cur_ctx: u32 = 0,
    point: u32 = 0,
    pending: std.ArrayList(u32) = .empty,
    demands: std.ArrayList(Demand) = .empty,
    ov_memo: std.AutoHashMapUnmanaged([3]u32, Ov) = .empty,
    route_index: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
    route_count: u32 = 0,
    sep_memo: std.AutoHashMapUnmanaged(u32, Cond) = .empty,
    unsupported: ?[]const u8 = null,
    // The contract being read off.
    res_arrs: std.AutoHashMapUnmanaged(u32, std.ArrayList(Arr)) = .empty,
    desc_seen: std.AutoHashMapUnmanaged([3]u32, void) = .empty,
    writes: std.ArrayList(WSlot) = .empty,
    req: Cond = .{},
    params: []PlaceId = &.{},
    result_place: PlaceId = .none,

    fn charge(b: *Body, cat: Ids.Category, n: u32) Error!void {
        try b.st.account.reserve(cat, n);
    }
    fn places(b: *Body) *Place.Table {
        return &b.s.mod.places;
    }
    fn gc(b: *Body) Ids.Charge {
        return .growth(&b.st.account);
    }
    fn bir(b: *Body) *const Bir {
        return b.s.in.bir;
    }
    fn tag(b: *Body, i: u32) Bir.Inst.Tag {
        return b.bir().instTag(@fromBackingInt(i));
    }
    fn data(b: *Body, i: u32) Bir.Inst.Data {
        return b.bir().instData(@fromBackingInt(i));
    }
    fn unsup(b: *Body, why: []const u8) void {
        if (b.unsupported == null) b.unsupported = why;
    }
    fn mk(b: *Body, v: Val) Error!u32 {
        try b.charge(.shape, 1);
        b.st.stats.values += 1;
        try b.vals.append(b.arena, v);
        return @intCast(b.vals.items.len - 1);
    }
    fn val(b: *Body, id: u32) Val {
        return b.vals.items[id];
    }
    fn kidsOf(b: *Body, v: Val) []const u32 {
        return b.kids.items[v.kids.start..][0..v.kids.len];
    }
    fn mkKids(b: *Body, ks: []const u32) Error!Ids.Range {
        const start: u32 = @intCast(b.kids.items.len);
        try b.kids.appendSlice(b.arena, ks);
        return .{ .start = start, .len = @intCast(ks.len) };
    }
    fn placeOfInst(b: *Body, i: u32) Error!PlaceId {
        return Groups.Module.placeOfInst(b.s.mod, i);
    }
    fn placeOfLocal(b: *Body, l: u32) Error!PlaceId {
        return Groups.Module.placeOfLocal(b.s.mod, l);
    }
    fn holdsAt(b: *Body, p: PlaceId) bool {
        if (p == .none) return true;
        const pl = b.places();
        return !pl.holds(p).isEmpty() or !Place.Kind.own(pl.kind(p)).isEmpty();
    }
    fn isObj(b: *Body, path: PathId) bool {
        return !Place.Kind.own(b.places().kind(b.places().pathPlace(path))).isEmpty();
    }
};

fn evalDecl(s: *Slots, st: *DeclState, final: bool) Error!*Contract {
    const gpa = s.gpa;
    const d = s.in.bir.decls[st.di];
    var b: Body = .{ .s = s, .st = st, .arena_state = .init(gpa), .arena = undefined, .final = final, .d = d, .locals_start = d.locals_start };
    b.arena = b.arena_state.allocator();
    defer {
        st.stats.peak_bytes = @max(st.stats.peak_bytes, b.arena_state.queryCapacity());
        b.arena_state.deinit();
    }
    st.stats.evaluations += 1;
    const total0 = st.account.total();
    const walk_index = st.stats.evaluations - 1;
    defer if (walk_index < 16) {
        st.stats.walks[walk_index] = st.account.total() - total0;
    };
    st.stats.slots = 0;
    s.mod.cur_locals = d.locals_start;
    Groups.charging(s.mod, &st.account);
    defer Groups.charging(s.mod, &s.mod.base_account);
    try b.ctxs.append(b.arena, .{ .parent = none, .case = none, .arm = 0, .depth = 0 });
    // Places of the parameters and the result.
    var ps: std.ArrayList(PlaceId) = .empty;
    const result_place = try Groups.declPlaces(s.mod, d, st.di, &ps);
    b.params = ps.items;
    b.result_place = result_place;
    const c = try s.arena.create(Contract);
    c.* = .{ .nparams = d.params };
    if (d.params > max_params) {
        c.unsupported = "more than 16 parameters";
        st.unsupported = c.unsupported;
        return c;
    }
    // Parameters: roots.
    const params = s.in.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.Inst.Index);
    for (params, 0..) |p, k| {
        const place = ps.items[k];
        const path = try b.places().rootPath(gpa, place);
        const root: u32 = @intCast(b.roots.items.len);
        try b.roots.append(b.arena, .{ .kind = .param, .a = @intCast(k), .place = place, .path = path, .pos = none });
        const rp = try rootPos(&b, root);
        b.roots.items[root].pos = rp;
        const v = if (b.holdsAt(place)) try b.mk(.{ .kind = .ref, .a = root, .b = rp }) else try b.mk(.{ .kind = .scalar });
        b.point += 1;
        if (!try bind(&b, p.int(), v)) {}
        st.stats.slots += @intCast((try closureOf(&b, path)).len);
    }
    const body_inst = d.body.unwrap() orelse {
        c.unsupported = "no body";
        return c;
    };
    const res = try eval(&b, body_inst.int());
    b.point += 1;
    if (b.unsupported) |why| {
        c.unsupported = why;
        st.unsupported = why;
        return c;
    }
    // The demands, offline: every use is known now.
    try resolveDemands(&b);
    // Read the contract off the result.
    const rpath = try b.places().rootPath(gpa, result_place);
    st.stats.slots += @intCast((try closureOf(&b, rpath)).len);
    c.res_cross = !b.holdsAt(result_place);
    const rv = b.val(res);
    c.returns = rv.kind != .bot;
    st.stats.arrivals = 0;
    if (!c.res_cross and c.returns) {
        try describe(&b, res, rpath);
        c.res_cond = try sepOf(&b, res);
        var slots: std.ArrayList(ResSlot) = .empty;
        var it = b.res_arrs.iterator();
        while (it.next()) |e| {
            const arrs = e.value_ptr.items;
            std.mem.sort(Arr, arrs, {}, arrLess);
            const path: PathId = .from(e.key_ptr.*);
            try slots.append(s.arena, .{ .steps = try stepsOf(&b, path), .var_leaf = b.places().kind(b.places().pathPlace(path)) == .@"var", .arrs = try s.arena.dupe(Arr, arrs) });
            st.stats.arrivals += @intCast(arrs.len);
        }
        std.mem.sort(ResSlot, slots.items, {}, struct {
            fn lt(_: void, x: ResSlot, y: ResSlot) bool {
                return std.mem.order(u32, x.steps, y.steps) == .lt;
            }
        }.lt);
        c.res = slots.items;
    }
    std.mem.sort(WSlot, b.writes.items, {}, wLess);
    var ws: std.ArrayList(WSlot) = .empty;
    for (b.writes.items) |w| {
        if (ws.items.len != 0 and ws.items[ws.items.len - 1].j == w.j and std.mem.eql(u32, ws.items[ws.items.len - 1].steps, w.steps)) continue;
        try ws.append(s.arena, w);
    }
    c.writes = ws.items;
    c.req = b.req;
    return c;
}

// ---------------------------------------------------------------------------
// Positions, slot sets, closures, tags
// ---------------------------------------------------------------------------

fn rootPos(b: *Body, root: u32) Error!u32 {
    try b.charge(.path, 1);
    const id: u32 = @intCast(b.pos.items.len);
    try b.pos.append(b.arena, .{ .parent = none, .step = .{ .kind = .plain }, .root = root, .slot = b.roots.items[root].path, .depth = 0 });
    b.st.stats.positions += 1;
    return id;
}

/// The child of position `p` by `step`, normalised so a slice is only ever
/// a last step: `xs[a..]` then `[i]` is `xs[a+i]`.
fn childPos(b: *Body, p: u32, step0: PStep) Error!?u32 {
    var parent = p;
    var step = step0;
    const ps = b.pos.items[p];
    if (ps.step.kind == .slice and ps.parent != none) {
        switch (step.kind) {
            .front => {
                parent = ps.parent;
                step = .{ .kind = .front, .a = ps.step.a + step.a };
            },
            .back => {
                parent = ps.parent;
                step = .{ .kind = .back, .a = ps.step.b + step.a };
            },
            .slice => {
                parent = ps.parent;
                step = .{ .kind = .slice, .a = ps.step.a + step.a, .b = ps.step.b + step.b };
            },
            .plain => {},
        }
    }
    try b.charge(.path, 1);
    const key: [4]u32 = .{ parent, @backingInt(step.kind), step.a, step.b };
    if (b.pos_index.get(key)) |hit| return hit;
    const pp = b.pos.items[parent];
    const slot: PathId = switch (step.kind) {
        .plain => (try b.places().extend(b.s.gpa, b.gc(), pp.slot, Step.fromWord(step.a))) orelse return null,
        .front, .back => (try b.places().extend(b.s.gpa, b.gc(), pp.slot, Step.elem)) orelse return null,
        .slice => pp.slot,
    };
    const id: u32 = @intCast(b.pos.items.len);
    try b.pos.append(b.arena, .{ .parent = parent, .step = step, .root = pp.root, .slot = slot, .depth = pp.depth + 1 });
    try b.pos_index.put(b.arena, key, id);
    b.st.stats.positions += 1;
    return id;
}

/// The object slots at and below canonical path `p` (BFS by `extend`).
fn closureOf(b: *Body, p: PathId) Error![]const u32 {
    try b.charge(.memo, 1);
    if (b.s.closure_memo.get(p.int())) |hit| return hit;
    const gpa = b.s.gpa;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    var queue: std.ArrayList(PathId) = .empty;
    defer queue.deinit(gpa);
    var out: std.ArrayList(u32) = .empty;
    try queue.append(gpa, p);
    try seen.put(gpa, p.int(), {});
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const at = queue.items[qi];
        try b.charge(.path, 1);
        if (b.isObj(at)) try out.append(b.s.arena, at.int());
        const place = b.places().pathPlace(at);
        const steps = b.places().steps(place);
        for (steps.steps) |stp| {
            const nx = (try b.places().extend(gpa, b.gc(), at, stp)) orelse continue;
            if ((try seen.getOrPut(gpa, nx.int())).found_existing) continue;
            try queue.append(gpa, nx);
        }
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    try b.s.closure_memo.put(gpa, p.int(), out.items);
    return out.items;
}

/// A slot's canonical names: a `⟲` that joins several level paths (a type
/// like `B (List B) (List B)`) stands for each of them (`Place.expandLevels`),
/// so two slots meet exactly when their canonical names do.
fn canon(b: *Body, p: u32) Error![]const u32 {
    try b.charge(.memo, 1);
    if (b.s.canon_memo.get(p)) |hit| return hit;
    var out: std.ArrayList(PathId) = .empty;
    defer out.deinit(b.s.gpa);
    try b.places().expandLevels(b.s.gpa, b.gc(), .from(p), &out);
    const own = try b.s.arena.alloc(u32, out.items.len);
    for (out.items, own) |x, *o| o.* = x.int();
    try b.s.canon_memo.put(b.s.gpa, p, own);
    return own;
}

fn internSet(b: *Body, items_in: []const u32) Error!u32 {
    var expanded: std.ArrayList(u32) = .empty;
    defer expanded.deinit(b.s.gpa);
    for (items_in) |x| for (try canon(b, x)) |c| if (b.isObj(.from(c))) try expanded.append(b.s.gpa, c);
    const items0 = expanded.items;
    var items = try b.arena.dupe(u32, items0);
    std.mem.sort(u32, items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (items) |x| {
        if (n != 0 and items[n - 1] == x) continue;
        items[n] = x;
        n += 1;
    }
    items = items[0..n];
    try b.charge(.set, @intCast(@max(1, n)));
    const key = std.mem.sliceAsBytes(items);
    if (b.set_index.get(key)) |hit| return hit;
    const start: u32 = @intCast(b.sets.items.len);
    try b.sets.appendSlice(b.arena, items);
    const id: u32 = @intCast(b.set_ranges.items.len);
    try b.set_ranges.append(b.arena, .{ .start = start, .len = @intCast(n) });
    try b.set_index.put(b.arena, try b.arena.dupe(u8, key), id);
    return id;
}

fn setItems(b: *Body, id: u32) []const u32 {
    const r = b.set_ranges.items[id];
    return b.sets.items[r.start..][0..r.len];
}

fn setsMeet(b: *Body, x: u32, y: u32) Error!bool {
    const xs = setItems(b, x);
    const ys = setItems(b, y);
    try b.charge(.inspection, @intCast(@max(1, xs.len + ys.len)));
    var i: usize = 0;
    var j: usize = 0;
    while (i < xs.len and j < ys.len) {
        if (xs[i] == ys[j]) return true;
        if (xs[i] < ys[j]) i += 1 else j += 1;
    }
    return false;
}

fn setHas(b: *Body, x: u32, item: u32) bool {
    for (setItems(b, x)) |y| if (y == item) return true;
    return false;
}

/// The deep closure of a set of slots: their object slots and everything
/// below.
fn deepSet(b: *Body, tops: []const u32) Error!u32 {
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(b.s.gpa);
    for (tops) |t| try all.appendSlice(b.s.gpa, try closureOf(b, .from(t)));
    return internSet(b, all.items);
}

fn internTags(b: *Body, words0: []const [2]u32) Error!u32 {
    if (words0.len == 0) return 0;
    const words = try b.arena.dupe([2]u32, words0);
    std.mem.sort([2]u32, words, {}, struct {
        fn lt(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
        }
    }.lt);
    try b.charge(.set, @intCast(words.len));
    const key = std.mem.sliceAsBytes(words);
    if (b.tag_index.get(key)) |hit| return hit;
    if (b.tag_ranges.items.len == 0) {
        try b.tag_ranges.append(b.arena, .{});
    }
    const start: u32 = @intCast(b.tag_words.items.len);
    try b.tag_words.appendSlice(b.arena, words);
    const id: u32 = @intCast(b.tag_ranges.items.len);
    try b.tag_ranges.append(b.arena, .{ .start = start, .len = @intCast(words.len) });
    try b.tag_index.put(b.arena, try b.arena.dupe(u8, key), id);
    return id;
}

fn tagItems(b: *Body, id: u32) []const [2]u32 {
    if (id == 0) return &.{};
    const r = b.tag_ranges.items[id];
    return b.tag_words.items[r.start..][0..r.len];
}

/// The union of two tag sets, or null when they name two arms of one
/// choice (never together).
fn tagsMerge(b: *Body, x: u32, y: u32) Error!?u32 {
    if (x == 0) return y;
    if (y == 0 or x == y) return x;
    const xs = tagItems(b, x);
    const ys = tagItems(b, y);
    try b.charge(.inspection, @intCast(xs.len + ys.len));
    for (xs) |p| for (ys) |q| if (p[0] == q[0] and p[1] != q[1]) return null;
    var all: std.ArrayList([2]u32) = .empty;
    defer all.deinit(b.s.gpa);
    try all.appendSlice(b.s.gpa, xs);
    for (ys) |q| {
        const found = for (xs) |p| {
            if (p[0] == q[0]) break true;
        } else false;
        if (!found) try all.append(b.s.gpa, q);
    }
    return try internTags(b, all.items);
}

fn mkLeaf(b: *Body, l: Leaf) Error!u32 {
    try b.charge(.cell, 1);
    const key: [6]u32 = .{ @backingInt(l.kind), l.root, l.pos, l.slots, l.tags, @intFromBool(l.at_pos) };
    if (b.leaf_index.get(key)) |hit| return hit;
    const id: u32 = @intCast(b.leaves.items.len);
    try b.leaves.append(b.arena, l);
    try b.leaf_index.put(b.arena, key, id);
    b.st.stats.leaves += 1;
    return id;
}

fn withTags(b: *Body, leaf: u32, tags: u32) Error!?u32 {
    if (tags == 0) return leaf;
    var l = b.leaves.items[leaf];
    l.tags = (try tagsMerge(b, l.tags, tags)) orelse return null;
    return try mkLeaf(b, l);
}

fn stepsOf(b: *Body, p: PathId) Error![]const u32 {
    try b.charge(.memo, 1);
    if (b.s.steps_memo.get(p.int())) |hit| return hit;
    var out: std.ArrayList(u32) = .empty;
    var at = p;
    const pl = b.places();
    while (pl.pathParent(at) != .none) : (at = pl.pathParent(at)) {
        try b.charge(.path, 1);
        try out.append(b.s.arena, pl.pathStep(at).word());
    }
    std.mem.reverse(u32, out.items);
    try b.s.steps_memo.put(b.s.gpa, p.int(), out.items);
    return out.items;
}

fn replay(b: *Body, from: PathId, steps: []const u32) Error!?PathId {
    var at = from;
    for (steps) |w| at = (try b.places().extend(b.s.gpa, b.gc(), at, Step.fromWord(w))) orelse return null;
    return at;
}

/// Every canonical path at and below `p` (BFS by `extend`), memoised.
fn belowAll(b: *Body, p: PathId) Error![]const u32 {
    try b.charge(.memo, 1);
    if (b.s.below_memo.get(p.int())) |hit| return hit;
    const gpa = b.s.gpa;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(gpa);
    var out: std.ArrayList(u32) = .empty;
    try out.append(b.s.arena, p.int());
    try seen.put(gpa, p.int(), {});
    var qi: usize = 0;
    while (qi < out.items.len) : (qi += 1) {
        const at: PathId = .from(out.items[qi]);
        try b.charge(.path, 1);
        for (b.places().steps(b.places().pathPlace(at)).steps) |stp| {
            const nx = (try b.places().extend(gpa, b.gc(), at, stp)) orelse continue;
            if ((try seen.getOrPut(gpa, nx.int())).found_existing) continue;
            try out.append(b.s.arena, nx.int());
        }
    }
    try b.s.below_memo.put(gpa, p.int(), out.items);
    return out.items;
}

/// `from · steps` as canonical paths: a callee's `⟲` replayed where this
/// frame's path is not a first return (a root, a plain step) is every
/// level below it at its own place, one or more, then the rest of the steps
/// from each — never a path `extend` would not name.
fn replaySet(b: *Body, from: PathId, steps: []const u32, out: *std.ArrayList(u32)) Error!void {
    const gpa = b.s.gpa;
    const pl = b.places();
    var cur: std.ArrayList(u32) = .empty;
    defer cur.deinit(gpa);
    var next: std.ArrayList(u32) = .empty;
    defer next.deinit(gpa);
    try cur.append(gpa, from.int());
    for (steps) |w| {
        const st = Step.fromWord(w);
        next.clearRetainingCapacity();
        for (cur.items) |a| {
            const at: PathId = .from(a);
            try b.charge(.path, 1);
            const folds = pl.pathParent(at) != .none and (pl.pathStep(at).kind == .level or pl.isReturn(at));
            if (st.kind == .level and !folds) {
                for (try belowAll(b, at)) |q| if (q != a and pl.pathPlace(.from(q)) == pl.pathPlace(at)) try next.append(gpa, q);
                continue;
            }
            const nx = (try pl.extend(gpa, b.gc(), at, st)) orelse continue;
            try next.append(gpa, nx.int());
        }
        std.mem.sort(u32, next.items, {}, std.sort.asc(u32));
        cur.clearRetainingCapacity();
        for (next.items) |x| if (cur.items.len == 0 or cur.items[cur.items.len - 1] != x) try cur.append(gpa, x);
        if (cur.items.len == 0) return;
    }
    try out.appendSlice(gpa, cur.items);
}

// ---------------------------------------------------------------------------
// Leaves of values
// ---------------------------------------------------------------------------

/// The deep leaves of value `v` (every object it reaches), appended.
fn leavesOf(b: *Body, v: u32, tags: u32, out: *std.ArrayList(u32)) Error!void {
    try b.charge(.inspection, 1);
    const x = b.val(v);
    switch (x.kind) {
        .scalar, .bot => {},
        .con => for (b.kidsOf(x)) |k| try leavesOf(b, k, tags, out),
        .obj => {
            try out.append(b.s.gpa, try mkLeaf(b, .{ .kind = .site, .root = x.a, .tags = tags }));
            for (b.kidsOf(x)) |k| try leavesOf(b, k, tags, out);
        },
        .ref => {
            const p = b.pos.items[x.b];
            const set = if (x.c == none) try deepSet(b, &.{p.slot.int()}) else try deepSet(b, setItems(b, x.c));
            if (setItems(b, set).len == 0) return;
            try out.append(b.s.gpa, try mkLeaf(b, .{ .kind = .ref, .root = x.a, .pos = x.b, .slots = set, .tags = tags }));
        },
        .alt => {
            const ks = b.kidsOf(x);
            var i: usize = 0;
            while (i < ks.len) : (i += 2) {
                const t = (try tagsMerge(b, tags, try internTags(b, &.{.{ x.a, ks[i] }}))) orelse continue;
                try leavesOf(b, ks[i + 1], t, out);
            }
        },
        .top => try out.append(b.s.gpa, try mkLeaf(b, .{ .kind = .top, .tags = tags })),
        .shared => try out.append(b.s.gpa, try mkLeaf(b, .{ .kind = .shared, .root = x.a, .tags = tags })),
    }
}

/// One projected object: its leaf, the literal route that reached it (the
/// concrete kid path taken through constructions built here; 0 for none),
/// and the selected occurrence it came from.
const Proj = struct { leaf: u32, route: u32, occ: u64 = 0 };
const LevelItem = struct { v: u32, place: PlaceId, route: u32, deep: bool };

fn routeStep(b: *Body, route: u32, kid: u32) Error!u32 {
    try b.charge(.path, 1);
    const g = try b.route_index.getOrPut(b.arena, .{ route, kid });
    if (!g.found_existing) {
        b.route_count += 1;
        g.value_ptr.* = b.route_count;
    }
    return g.value_ptr.*;
}

/// The shallow objects of `v` (at place `place`) at relative canonical steps
/// `steps`: what a callee's arrival at `steps` (or a write at them, or a
/// selected occurrence) names in this frame.
fn project(b: *Body, v: u32, place: PlaceId, steps: []const u32, tags: u32, out: *std.ArrayList(u32)) Error!void {
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(b.s.gpa);
    try projectR(b, v, place, steps, tags, 0, &ps);
    for (ps.items) |x| try out.append(b.s.gpa, x.leaf);
}

fn projectR(b: *Body, v: u32, place: PlaceId, steps: []const u32, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
    try b.charge(.inspection, 1);
    b.st.stats.substitutions += 1;
    const x = b.val(v);
    const gpa = b.s.gpa;
    if (steps.len == 0 and x.kind != .alt) switch (x.kind) {
        .obj => return out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .site, .root = x.a, .tags = tags }), .route = route }),
        .ref => {
            const p = b.pos.items[x.b];
            const tops: []const u32 = if (x.c == none) &.{p.slot.int()} else setItems(b, x.c);
            var objs: std.ArrayList(u32) = .empty;
            defer objs.deinit(gpa);
            for (tops) |t| if (b.isObj(.from(t))) try objs.append(gpa, t);
            if (objs.items.len == 0) return;
            const set = try internSet(b, objs.items);
            return out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .ref, .root = x.a, .pos = x.b, .slots = set, .tags = tags, .at_pos = x.c == none }), .route = route });
        },
        .top => return out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .top, .tags = tags }), .route = route }),
        .shared => return out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .shared, .root = x.a, .tags = tags }), .route = route }),
        else => return,
    };
    switch (x.kind) {
        .scalar, .bot => {},
        .top => try out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .top, .tags = tags }), .route = route }),
        .shared => try out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .shared, .root = x.a, .tags = tags }), .route = route }),
        .alt => {
            const ks = b.kidsOf(x);
            var i: usize = 0;
            while (i < ks.len) : (i += 2) {
                const t = (try tagsMerge(b, tags, try internTags(b, &.{.{ x.a, ks[i] }}))) orelse continue;
                try projectR(b, ks[i + 1], place, steps, t, route, out);
            }
        },
        .con, .obj => {
            const st = Step.fromWord(steps[0]);
            const pl = b.places();
            switch (st.kind) {
                .ctor_arg => if (x.kind == .con) {
                    const ca = pl.ctorArgOf(st);
                    if (ca[0] == x.a and ca[1] < x.kids.len) try projectR(b, b.kidsOf(x)[ca[1]], pl.child(place, st) orelse .none, steps[1..], tags, try routeStep(b, route, ca[1]), out);
                },
                .index => if (x.kind == .con and x.a == tuple_key and st.payload < x.kids.len) {
                    try projectR(b, b.kidsOf(x)[st.payload], pl.child(place, st) orelse .none, steps[1..], tags, try routeStep(b, route, st.payload), out);
                },
                .elem => if (x.kind == .obj and x.b == 0) {
                    for (b.kidsOf(x), 0..) |k, n| try projectR(b, k, pl.child(place, st) orelse .none, steps[1..], tags, try routeStep(b, route, @intCast(n)), out);
                },
                .field => if (x.kind == .obj and x.b == 1) {
                    const ranks = setItems(b, x.c);
                    for (ranks, 0..) |r, k| if (r == st.payload) try projectR(b, b.kidsOf(x)[k], pl.child(place, st) orelse .none, steps[1..], tags, try routeStep(b, route, @intCast(k)), out);
                },
                // `⟲`: the values one or more levels below, at this same place,
                // found through the parts that stay on its cycle.
                .level => {
                    if (place == .none) return projectWhole(b, v, tags, route, out);
                    var stack: std.ArrayList(LevelItem) = .empty;
                    defer stack.deinit(gpa);
                    try stack.append(gpa, .{ .v = v, .place = place, .route = route, .deep = false });
                    while (stack.pop()) |e| {
                        try b.charge(.inspection, 1);
                        const ev = b.val(e.v);
                        switch (ev.kind) {
                            .con, .obj => {
                                if (e.deep and e.place == place) try projectR(b, e.v, place, steps[1..], tags, e.route, out);
                                for (b.kidsOf(ev), 0..) |k, n| {
                                    const kst: Step = if (ev.kind == .obj and ev.b == 0) Step.elem else if (ev.kind == .obj) try Step.field(&b.st.account, setItems(b, ev.c)[n]) else if (ev.a == tuple_key) try Step.index(&b.st.account, @intCast(n)) else try pl.ctorStep(b.s.gpa, &b.st.account, ev.a, @intCast(n));
                                    const kp = pl.child(e.place, kst) orelse continue;
                                    if (kp != place and !pl.sameCycle(kp, place)) continue;
                                    try stack.append(gpa, .{ .v = k, .place = kp, .route = try routeStep(b, e.route, @intCast(n)), .deep = true });
                                }
                            },
                            .scalar, .bot => {},
                            // A part not built here: this level by the rest of the
                            // steps, the levels below by its own slots.
                            .ref => if (e.deep) {
                                if (e.place == place) try projectR(b, e.v, place, steps[1..], tags, e.route, out);
                                try projectLevelsRef(b, e.v, place, steps[1..], tags, e.route, out);
                            },
                            else => if (e.deep) {
                                if (e.place == place) {
                                    try projectR(b, e.v, place, steps[1..], tags, e.route, out);
                                    try projectR(b, e.v, place, steps, tags, e.route, out);
                                } else try projectWhole(b, e.v, tags, e.route, out);
                            },
                        }
                    }
                },
                else => try projectWhole(b, v, tags, route, out),
            }
        },
        .ref => {
            const p = b.pos.items[x.b];
            const tops: []const u32 = if (x.c == none) &.{p.slot.int()} else setItems(b, x.c);
            var objs: std.ArrayList(u32) = .empty;
            defer objs.deinit(gpa);
            var all: std.ArrayList(u32) = .empty;
            defer all.deinit(gpa);
            for (tops) |t| try replaySet(b, .from(t), steps, &all);
            for (all.items) |at| if (b.isObj(.from(at))) try objs.append(gpa, at);
            if (objs.items.len == 0) return;
            const set = try internSet(b, objs.items);
            try out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .ref, .root = x.a, .pos = x.b, .slots = set, .tags = tags }), .route = route });
        },
    }
}

/// The levels strictly below a reference that sit at `place` (a `⟲` met at
/// a part not built here), each followed by `rest`: its own descendant
/// paths, never its own storage.
fn projectLevelsRef(b: *Body, v: u32, place: PlaceId, rest: []const u32, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
    const gpa = b.s.gpa;
    const x = b.val(v);
    const p = b.pos.items[x.b];
    const tops: []const u32 = if (x.c == none) &.{p.slot.int()} else setItems(b, x.c);
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(gpa);
    for (tops) |t| for (try belowAll(b, .from(t))) |q| {
        if (q == t or b.places().pathPlace(.from(q)) != place) continue;
        try replaySet(b, .from(q), rest, &all);
    };
    var objs: std.ArrayList(u32) = .empty;
    defer objs.deinit(gpa);
    for (all.items) |at| if (b.isObj(.from(at))) try objs.append(gpa, at);
    if (objs.items.len == 0) return;
    const set = try internSet(b, objs.items);
    if (setItems(b, set).len == 0) return;
    try out.append(gpa, .{ .leaf = try mkLeaf(b, .{ .kind = .ref, .root = x.a, .pos = x.b, .slots = set, .tags = tags }), .route = route });
}

/// Every object of `v`, conservatively (a step the projection cannot follow).
fn projectWhole(b: *Body, v: u32, tags: u32, route: u32, out: *std.ArrayList(Proj)) Error!void {
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(b.s.gpa);
    try leavesOf(b, v, tags, &ls);
    for (ls.items) |l| try out.append(b.s.gpa, .{ .leaf = l, .route = try routeStep(b, route, none) });
}

// ---------------------------------------------------------------------------
// Overlap: the one relation
// ---------------------------------------------------------------------------

const Rel = enum { disjoint, related };

/// Whether two positions of one root may share a subtree.
fn relation(b: *Body, p1: u32, p2: u32) Error!struct { rel: Rel, t_prefix: bool } {
    var a = p1;
    var c = p2;
    var sa: std.ArrayList(PStep) = .empty;
    defer sa.deinit(b.s.gpa);
    var sc: std.ArrayList(PStep) = .empty;
    defer sc.deinit(b.s.gpa);
    while (a != none and b.pos.items[a].parent != none) : (a = b.pos.items[a].parent) try sa.append(b.s.gpa, b.pos.items[a].step);
    while (c != none and b.pos.items[c].parent != none) : (c = b.pos.items[c].parent) try sc.append(b.s.gpa, b.pos.items[c].step);
    std.mem.reverse(PStep, sa.items);
    std.mem.reverse(PStep, sc.items);
    try b.charge(.inspection, @intCast(1 + @min(sa.items.len, sc.items.len)));
    const n = @min(sa.items.len, sc.items.len);
    for (0..n) |k| {
        const x = sa.items[k];
        const y = sc.items[k];
        if (x.kind == y.kind and x.a == y.a and x.b == y.b) continue;
        if (x.kind == .plain or y.kind == .plain) return .{ .rel = .disjoint, .t_prefix = false };
        switch (x.kind) {
            .front => switch (y.kind) {
                .front => return .{ .rel = .disjoint, .t_prefix = false },
                .back => continue,
                .slice => return if (x.a < y.a) .{ .rel = .disjoint, .t_prefix = false } else .{ .rel = .related, .t_prefix = true },
                .plain => unreachable,
            },
            .back => switch (y.kind) {
                .back => return .{ .rel = .disjoint, .t_prefix = false },
                .front => continue,
                .slice => return if (x.a < y.b) .{ .rel = .disjoint, .t_prefix = false } else .{ .rel = .related, .t_prefix = true },
                .plain => unreachable,
            },
            .slice => switch (y.kind) {
                .front => return if (y.a < x.a) .{ .rel = .disjoint, .t_prefix = false } else .{ .rel = .related, .t_prefix = false },
                .back => return if (y.a < x.b) .{ .rel = .disjoint, .t_prefix = false } else .{ .rel = .related, .t_prefix = false },
                .slice => return .{ .rel = .related, .t_prefix = true },
                .plain => unreachable,
            },
            .plain => unreachable,
        }
    }
    // One is a prefix of the other: `t_prefix` when it is the second.
    return .{ .rel = .related, .t_prefix = sc.items.len <= sa.items.len };
}

/// `Sep` of a root: an assumption on a parameter, the instantiated callee
/// condition for a call.
fn selOf(b: *Body, j: u32, set: u32) Error!Cond {
    const items = setItems(b, set);
    try b.charge(.cond, @intCast(1 + items.len));
    const out = try b.s.arena.alloc(u64, items.len);
    for (items, out) |sl, *o| o.* = occ(j, try internSteps(b.s, try stepsOf(b, .from(sl))));
    std.mem.sort(u64, out, {}, std.sort.asc(u64));
    return .{ .sel = out };
}

/// `Sep` of the objects one leaf names: a parameter's, its selected slots;
/// a call's, the callee's condition on its arguments.
fn sepLeaf(b: *Body, l: Leaf) Error!Cond {
    const r = b.roots.items[l.root];
    return switch (r.kind) {
        .param => selOf(b, r.a, l.slots),
        .call => instCond(b, r.a),
    };
}

fn unionSet(b: *Body, x: u32, y: u32) Error!u32 {
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(b.s.gpa);
    try all.appendSlice(b.s.gpa, setItems(b, x));
    try all.appendSlice(b.s.gpa, setItems(b, y));
    return internSet(b, all.items);
}

/// Whether leaf `x` (a holder's, deep) and leaf `t` overlap; `target`:
/// `t` is a shallow write target.
fn overlap(b: *Body, x: u32, t: u32, target: bool) Error!Ov {
    b.st.stats.relation_facts += 1;
    try b.charge(.cond, 1);
    const key: [3]u32 = .{ x, t, @intFromBool(target) };
    if (b.ov_memo.get(key)) |hit| {
        b.st.stats.relation_memo_hits += 1;
        return hit;
    }
    const got = try overlapRaw(b, x, t, target);
    try b.ov_memo.put(b.arena, key, got);
    return got;
}

fn overlapRaw(b: *Body, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = b.leaves.items[xi];
    const t = b.leaves.items[ti];
    if ((try tagsMerge(b, x.tags, t.tags)) == null) return .no;
    if (x.kind == .top or t.kind == .top) return .may;
    // A call's leaf that meets a leaf of another root is expanded to its
    // arguments' (the later root first).
    const xr = x.kind == .ref;
    const tr = t.kind == .ref;
    if (xr and tr and x.root == t.root) return positional(b, xi, ti, target);
    if (xr or tr) {
        // Expand the later call root.
        var expand_x = false;
        if (xr and tr) {
            expand_x = x.root > t.root;
        } else expand_x = xr;
        const which = if (expand_x) x else t;
        const r = b.roots.items[which.root];
        if (r.kind == .call) {
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(b.s.gpa);
            try expandLeaf(b, if (expand_x) xi else ti, &list);
            var acc: Ov = .no;
            for (list.items) |e| {
                acc = acc.join(if (expand_x) try overlap(b, e, ti, target) else try overlap(b, xi, e, target));
                if (acc.yes) return acc;
            }
            return acc;
        }
        // A parameter's leaf: against another parameter's, apart under a
        // condition; against a fresh or shared atom, apart.
        if (xr and tr) {
            const other = b.roots.items[if (expand_x) t.root else x.root];
            if (other.kind == .call) {
                var list: std.ArrayList(u32) = .empty;
                defer list.deinit(b.s.gpa);
                try expandLeaf(b, if (expand_x) ti else xi, &list);
                var acc: Ov = .no;
                for (list.items) |e| {
                    acc = acc.join(if (expand_x) try overlap(b, xi, e, target) else try overlap(b, e, ti, target));
                    if (acc.yes) return acc;
                }
                return acc;
            }
            return .{ .cond = (try selOf(b, b.roots.items[x.root].a, x.slots)).conj(try selOf(b, b.roots.items[t.root].a, t.slots)) };
        }
        return .no;
    }
    // Two atoms.
    if (x.kind == t.kind and x.root == t.root) return .may;
    return .no;
}

fn positional(b: *Body, xi: u32, ti: u32, target: bool) Error!Ov {
    const x = b.leaves.items[xi];
    const t = b.leaves.items[ti];
    if (setItems(b, x.slots).len == 0 or setItems(b, t.slots).len == 0) return .no;
    const r = try relation(b, x.pos, t.pos);
    if (r.rel == .related) {
        if (try setsMeet(b, x.slots, t.slots)) return .may;
        // A write of a position's own storage never meets what lies inside
        // it: no value holds itself.
        if (target and t.at_pos and r.t_prefix) return .no;
    }
    // Two positions of one root: apart when the root's objects at both are
    // separated — for a parameter, the selection of exactly these slots.
    const r0 = b.roots.items[x.root];
    if (r0.kind == .param) return .{ .cond = try selOf(b, r0.a, try unionSet(b, x.slots, t.slots)) };
    const sep = try instCond(b, r0.a);
    if (sep.ok) return .{ .cond = sep };
    // The call's answer may repeat an object: where do the two parts come
    // from? Each side's arrivals, compared.
    var lx: std.ArrayList(u32) = .empty;
    defer lx.deinit(b.s.gpa);
    var lt: std.ArrayList(u32) = .empty;
    defer lt.deinit(b.s.gpa);
    try expandLeaf(b, xi, &lx);
    try expandLeaf(b, ti, &lt);
    var acc: Ov = .no;
    for (lx.items) |e| for (lt.items) |f| {
        acc = acc.join(try overlap(b, e, f, target));
        if (acc.yes) return acc;
    };
    return acc;
}

/// A call root's leaf as the leaves of the callee's arrivals at its slots,
/// projected onto the arguments at the call site.
fn expandLeaf(b: *Body, li: u32, out: *std.ArrayList(u32)) Error!void {
    const l = b.leaves.items[li];
    const r = b.roots.items[l.root];
    const call = &b.calls.items[r.a];
    for (setItems(b, l.slots)) |slot| {
        try b.charge(.memo, 1);
        const range = call.inst_map.get(slot) orelse continue;
        for (b.leaf_lists.items[range.start..][0..range.len]) |e| {
            if (try withTags(b, e, l.tags)) |te| try out.append(b.s.gpa, te);
        }
    }
}

fn expandFull(b: *Body, li: u32, out: *std.ArrayList(u32), depth: u32) Error!void {
    const l = b.leaves.items[li];
    if (l.kind == .ref and b.roots.items[l.root].kind == .call and depth < 256) {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(b.s.gpa);
        try expandLeaf(b, li, &list);
        for (list.items) |e| try expandFull(b, e, out, depth + 1);
        return;
    }
    try out.append(b.s.gpa, li);
}

/// `Sep(v)`: v's components each separated, all apart.
fn sepOf(b: *Body, v: u32) Error!Cond {
    try b.charge(.cond, 1);
    if (b.sep_memo.get(v)) |hit| return hit;
    var ls: std.ArrayList(u32) = .empty;
    defer ls.deinit(b.s.gpa);
    try leavesOf(b, v, 0, &ls);
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(b.s.gpa);
    // Each component its own route: one value placed twice is two entries.
    for (ls.items, 0..) |l, k| try ps.append(b.s.gpa, .{ .leaf = l, .route = @intCast(k + 1) });
    const acc = try distinct(b, ps.items, false);
    try b.sep_memo.put(b.arena, v, acc);
    return acc;
}

const Ent = struct { leaf: u32, route: u32, occ: u64, block: u32 };

/// Every object the entries name is distinct from every other's: the
/// factored check, never a table of pairs. Entries of one root conflict only
/// at related positions with meeting slots (found through each entry's
/// ancestors); otherwise they are apart when the root is separated on the
/// union of their slots (a parameter's selection, a call's condition). Two
/// parameters are apart under both selections; two fresh atoms only when
/// they differ. A call meeting another root is expanded into its arguments'
/// entries, the latest call first, its entries then one block the call has
/// vouched for. `routed`: entries of one literal route and position from
/// distinct occurrences are distinct positions (`instSel`).
fn distinct(b: *Body, ps: []const Proj, routed: bool) Error!Cond {
    const gpa = b.s.gpa;
    var ents: std.ArrayList(Ent) = .empty;
    defer ents.deinit(gpa);
    for (ps) |p| try ents.append(gpa, .{ .leaf = p.leaf, .route = p.route, .occ = p.occ, .block = none });
    var acc: Cond = .{};
    for (ents.items) |e| {
        const l = b.leaves.items[e.leaf];
        switch (l.kind) {
            .ref => if (!l.at_pos) {
                acc = acc.conj(try sepLeaf(b, l));
                if (!acc.ok) return .no;
            },
            .top, .shared => return .no,
            else => {},
        }
    }
    var next: std.ArrayList(Ent) = .empty;
    defer next.deinit(gpa);
    while (true) {
        try b.charge(.cond, @intCast(1 + ents.items.len));
        var groups: std.AutoArrayHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
        defer {
            for (groups.values()) |*g| g.deinit(gpa);
            groups.deinit(gpa);
        }
        var atoms: std.AutoHashMapUnmanaged([2]u32, std.ArrayList(u32)) = .empty;
        defer {
            var ai = atoms.valueIterator();
            while (ai.next()) |g| g.deinit(gpa);
            atoms.deinit(gpa);
        }
        var latest_call: u32 = none;
        for (ents.items, 0..) |e, i| {
            const l = b.leaves.items[e.leaf];
            switch (l.kind) {
                .ref => {
                    const g = try groups.getOrPut(gpa, l.root);
                    if (!g.found_existing) g.value_ptr.* = .empty;
                    try g.value_ptr.append(gpa, @intCast(i));
                    if (b.roots.items[l.root].kind == .call and (latest_call == none or l.root > latest_call)) latest_call = l.root;
                },
                .site, .callfresh => {
                    const g = try atoms.getOrPut(gpa, .{ @backingInt(l.kind), l.root });
                    if (!g.found_existing) g.value_ptr.* = .empty;
                    for (g.value_ptr.items) |fi| {
                        const f = ents.items[fi];
                        if (f.block != none and f.block == e.block) continue;
                        if ((try tagsMerge(b, l.tags, b.leaves.items[f.leaf].tags)) != null) return .no;
                    }
                    try g.value_ptr.append(gpa, @intCast(i));
                },
                else => {},
            }
        }
        var params: u32 = 0;
        for (groups.keys()) |root| if (b.roots.items[root].kind == .param) {
            params += 1;
        };
        var it = groups.iterator();
        while (it.next()) |kv| {
            const root = kv.key_ptr.*;
            const idx = kv.value_ptr.items;
            if (try mayWithin(b, ents.items, idx, routed)) return .no;
            const r = b.roots.items[root];
            if (idx.len >= 2 or (r.kind == .param and params >= 2)) {
                acc = acc.conj(switch (r.kind) {
                    .param => blk: {
                        var all: std.ArrayList(u32) = .empty;
                        defer all.deinit(gpa);
                        for (idx) |i| try all.appendSlice(gpa, setItems(b, b.leaves.items[ents.items[i].leaf].slots));
                        break :blk try selOf(b, r.a, try internSet(b, all.items));
                    },
                    .call => if (idx.len >= 2) try instCond(b, r.a) else Cond.yes,
                });
                if (!acc.ok) return .no;
            }
        }
        if (latest_call == none or groups.count() + atoms.count() < 2) break;
        // The latest call meets another root: its entries become its
        // arguments' (one level), a block it vouched for.
        next.clearRetainingCapacity();
        // An expansion's entries are alternatives within one block: one
        // entry per leaf, and no route of their own (the routed rule is for
        // a callee's own occurrences only).
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(gpa);
        for (ents.items) |e| {
            const l = b.leaves.items[e.leaf];
            if (l.kind != .ref or l.root != latest_call) {
                try next.append(gpa, e);
                continue;
            }
            var list: std.ArrayList(u32) = .empty;
            defer list.deinit(gpa);
            try expandLeaf(b, e.leaf, &list);
            for (list.items) |x| {
                const xl = b.leaves.items[x];
                if (xl.kind == .top or xl.kind == .shared) return .no;
                if ((try seen.getOrPut(gpa, x)).found_existing) continue;
                try b.charge(.edge, 1);
                b.route_count += 1;
                try next.append(gpa, .{ .leaf = x, .route = 0x4000_0000 | b.route_count, .occ = 0, .block = latest_call });
            }
        }
        std.mem.swap(std.ArrayList(Ent), &ents, &next);
    }
    return acc;
}

/// Whether two entries of one root may name one object: at related
/// positions whose slots meet. Through each entry's ancestors, or pairwise
/// in a small group or one with list positions (whose relations are not
/// ancestry).
fn mayWithin(b: *Body, ents: []const Ent, idx: []const u32, routed: bool) Error!bool {
    if (idx.len < 2) return false;
    const gpa = b.s.gpa;
    var listy = idx.len <= 8;
    if (!listy) for (idx) |i| {
        var p = b.leaves.items[ents[i].leaf].pos;
        while (p != none and b.pos.items[p].parent != none) : (p = b.pos.items[p].parent) {
            if (b.pos.items[p].step.kind != .plain) listy = true;
        }
    };
    if (listy) {
        for (idx, 0..) |i, k| for (idx[k + 1 ..]) |j| {
            if (try pairMay(b, ents[i], ents[j], routed)) return true;
        };
        return false;
    }
    // Per (position, slot), the entries that claim it: a conflict is a slot
    // claimed at a position and at it or one of its ancestors.
    var at: std.AutoHashMapUnmanaged([2]u32, std.ArrayList(u32)) = .empty;
    defer {
        var ai = at.valueIterator();
        while (ai.next()) |g| g.deinit(gpa);
        at.deinit(gpa);
    }
    for (idx) |i| {
        const l = b.leaves.items[ents[i].leaf];
        for (setItems(b, l.slots)) |sl| {
            try b.charge(.inspection, 1);
            const g = try at.getOrPut(gpa, .{ l.pos, sl });
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(gpa, i);
        }
    }
    for (idx) |i| {
        const l = b.leaves.items[ents[i].leaf];
        var p = l.pos;
        while (p != none) : (p = b.pos.items[p].parent) {
            for (setItems(b, l.slots)) |sl| {
                try b.charge(.inspection, 1);
                const here = at.get(.{ p, sl }) orelse continue;
                for (here.items) |j| {
                    if (j == i) continue;
                    // Each unordered pair at one position once.
                    if (p == l.pos and j > i) continue;
                    if (try pairMay(b, ents[i], ents[j], routed)) return true;
                }
            }
        }
    }
    return false;
}

fn pairMay(b: *Body, e: Ent, f: Ent, routed: bool) Error!bool {
    try b.charge(.cond, 1);
    b.st.stats.relation_facts += 1;
    if (e.block != none and e.block == f.block) return false;
    if (e.leaf == f.leaf and e.route == f.route and e.occ == f.occ) return false;
    const le = b.leaves.items[e.leaf];
    const lf = b.leaves.items[f.leaf];
    if ((try tagsMerge(b, le.tags, lf.tags)) == null) return false;
    // Two distinct positions of a callee at one value of this frame.
    if (routed and e.route == f.route and e.occ != f.occ and le.pos == lf.pos) return false;
    const r = try relation(b, le.pos, lf.pos);
    return r.rel == .related and try setsMeet(b, le.slots, lf.slots);
}

/// The callee's `res_cond` on the arguments of call `ci`, once per call.
fn instCond(b: *Body, ci: u32) Error!Cond {
    if (b.calls.items[ci].cond) |c| return c;
    const call = b.calls.items[ci];
    // Mark first, so a cycle through this call's own condition reads it as
    // unproved.
    b.calls.items[ci].cond = .no;
    const acc = try instSel(b, call.contract.res_cond, call.args, call.places);
    b.calls.items[ci].cond = acc;
    return acc;
}

/// A callee's condition (a selection over its parameters) on the arguments:
/// every object at a selected occurrence, projected onto the arguments,
/// distinct from every other. Two distinct occurrences of the callee that
/// land in one value of this frame by one literal route are two distinct
/// positions of it: they ask that value's own separation, never a refusal
/// (separation survives substitution when two formal arrivals become one
/// actual). Two by different routes are the same value placed twice.
fn instSel(b: *Body, cond: Cond, args: []const u32, places: []const PlaceId) Error!Cond {
    if (!cond.ok) return .no;
    if (cond.sel.len == 0 and !cond.all) return .yes;
    var ps: std.ArrayList(Proj) = .empty;
    defer ps.deinit(b.s.gpa);
    if (cond.all) for (args, 0..) |a, j| {
        var ls: std.ArrayList(u32) = .empty;
        defer ls.deinit(b.s.gpa);
        try leavesOf(b, a, 0, &ls);
        for (ls.items) |l| try ps.append(b.s.gpa, .{ .leaf = l, .route = 0, .occ = occ(@intCast(j), none) });
    };
    for (cond.sel) |o| {
        const j: u32 = @intCast(o >> 32);
        if (j >= args.len) continue;
        const start = ps.items.len;
        // Each parameter's own route: two parameters handed one value are
        // that value twice, never two positions of it.
        try projectR(b, args[j], places[j], b.s.steps_tab.items[@as(u32, @truncate(o))], 0, try routeStep(b, 0, 0x8000_0000 | j), &ps);
        for (ps.items[start..]) |*e| e.occ = o;
    }
    return distinct(b, ps.items, true);
}

// ---------------------------------------------------------------------------
// Reading off the contract: arrivals per result slot
// ---------------------------------------------------------------------------

fn addArr(b: *Body, q: PathId, a: Arr) Error!void {
    if (!b.isObj(q)) return;
    try b.charge(.label, 1);
    const gop = try b.res_arrs.getOrPut(b.arena, q.int());
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |x| if (arrEql(x, a)) return;
    try gop.value_ptr.append(b.arena, a);
}

fn describe(b: *Body, v: u32, q: PathId) Error!void {
    try b.charge(.inspection, 1);
    const gop = try b.desc_seen.getOrPut(b.arena, .{ 0, v, q.int() });
    if (gop.found_existing) return;
    const x = b.val(v);
    switch (x.kind) {
        .scalar, .bot => {},
        .con => for (b.kidsOf(x), 0..) |k, i| {
            const st: Step = if (x.a == tuple_key) try Step.index(&b.st.account, @intCast(i)) else try b.places().ctorStep(b.s.gpa, &b.st.account, x.a, @intCast(i));
            const q2 = (try b.places().extend(b.s.gpa, b.gc(), q, st)) orelse continue;
            try describe(b, k, q2);
        },
        .obj => {
            try addArr(b, q, .{ .kind = .fresh });
            if (x.b == 0) {
                const q2 = (try b.places().extend(b.s.gpa, b.gc(), q, Step.elem)) orelse return;
                for (b.kidsOf(x)) |k| try describe(b, k, q2);
            } else {
                const ranks = setItems(b, x.c);
                for (b.kidsOf(x), 0..) |k, i| {
                    const q2 = (try b.places().extend(b.s.gpa, b.gc(), q, try Step.field(&b.st.account, ranks[i]))) orelse continue;
                    try describe(b, k, q2);
                }
            }
        },
        .ref => {
            const p = b.pos.items[x.b];
            const tops: []const u32 = if (x.c == none) &.{p.slot.int()} else setItems(b, x.c);
            const r = b.roots.items[x.a];
            for (tops) |t| switch (r.kind) {
                .param => try lockParam(b, q, .from(t), r.a),
                .call => try lockCall(b, q, x.a, .from(t)),
            };
        },
        .alt => {
            const ks = b.kidsOf(x);
            var i: usize = 0;
            while (i < ks.len) : (i += 2) try describe(b, ks[i + 1], q);
        },
        .top => try lockAtom(b, q, .{ .kind = .top }),
        .shared => try lockAtom(b, q, .{ .kind = .shared }),
    }
}

fn lockParam(b: *Body, q: PathId, s: PathId, j: u32) Error!void {
    const gop = try b.desc_seen.getOrPut(b.arena, .{ 1 + j, q.int(), s.int() });
    if (gop.found_existing) return;
    try b.charge(.inspection, 1);
    try addArr(b, q, .{ .kind = .param, .j = j, .steps = try stepsOf(b, s) });
    const steps = b.places().steps(b.places().pathPlace(q));
    for (steps.steps) |stp| {
        const q2 = (try b.places().extend(b.s.gpa, b.gc(), q, stp)) orelse continue;
        const s2 = (try b.places().extend(b.s.gpa, b.gc(), s, stp)) orelse continue;
        try lockParam(b, q2, s2, j);
    }
}

fn lockCall(b: *Body, q: PathId, root: u32, r: PathId) Error!void {
    const gop = try b.desc_seen.getOrPut(b.arena, .{ 0x8000_0000 | root, q.int(), r.int() });
    if (gop.found_existing) return;
    try b.charge(.inspection, 1);
    const call = &b.calls.items[b.roots.items[root].a];
    if (call.inst_map.get(r.int())) |range| {
        for (b.leaf_lists.items[range.start..][0..range.len]) |e| {
            var full: std.ArrayList(u32) = .empty;
            defer full.deinit(b.s.gpa);
            try expandFull(b, e, &full, 0);
            for (full.items) |f| {
                const l = b.leaves.items[f];
                switch (l.kind) {
                    .ref => {
                        const pr = b.roots.items[l.root];
                        if (pr.kind != .param) {
                            try addArr(b, q, .{ .kind = .top });
                            continue;
                        }
                        for (setItems(b, l.slots)) |sl| try addArr(b, q, .{ .kind = .param, .j = pr.a, .steps = try stepsOf(b, .from(sl)) });
                    },
                    .site, .callfresh => try addArr(b, q, .{ .kind = .fresh }),
                    .top => try addArr(b, q, .{ .kind = .top }),
                    .shared => try addArr(b, q, .{ .kind = .shared }),
                }
            }
        }
    }
    const steps = b.places().steps(b.places().pathPlace(q));
    for (steps.steps) |stp| {
        const q2 = (try b.places().extend(b.s.gpa, b.gc(), q, stp)) orelse continue;
        const r2 = (try b.places().extend(b.s.gpa, b.gc(), r, stp)) orelse continue;
        try lockCall(b, q2, root, r2);
    }
}

fn lockAtom(b: *Body, q: PathId, a: Arr) Error!void {
    for (try closureOf(b, q)) |sl| try addArr(b, .from(sl), a);
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

fn useLocal(b: *Body, local: u32, token: u32) Error!void {
    try b.charge(.use, 1);
    b.point += 1;
    try b.uses.append(b.arena, .{ .local = local, .point = b.point, .ctx = b.cur_ctx, .token = token });
}

fn setLocal(b: *Body, local: u32, v: u32, token: u32) Error!void {
    try b.charge(.label, 1);
    try b.locals.put(b.arena, local, v);
    try b.bound_at.put(b.arena, local, b.point);
    try b.local_token.put(b.arena, local, token);
}

fn eval(b: *Body, i: u32) Error!u32 {
    try b.charge(.inspection, 1);
    if (b.unsupported != null) return b.mk(.{ .kind = .top });
    const d = b.data(i);
    const bir = b.bir();
    switch (b.tag(i)) {
        .local => {
            try useLocal(b, d.lhs, bir.insts.items(.main_token)[i]);
            return b.locals.get(d.lhs) orelse b.mk(.{ .kind = .scalar });
        },
        .int, .float, .char, .string, .chunk, .unit => return b.mk(.{ .kind = .scalar }),
        .interp => {
            for (bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index)) |e| _ = try evalPending(b, e.int());
            popPending(b, bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index).len);
            return b.mk(.{ .kind = .scalar });
        },
        .ctor, .ext_ctor => {
            const c = Groups.Module.ctorOf(b.s.mod, i) orelse {
                b.unsup("constructor");
                return b.mk(.{ .kind = .top });
            };
            if (c[1] != 0) {
                b.unsup("constructor as a function value");
                return b.mk(.{ .kind = .top });
            }
            return b.mk(.{ .kind = .con, .a = c[0] });
        },
        .top, .ext_value => {
            // A parameterless value: shared, never this activation's.
            if (!b.holdsAt(try b.placeOfInst(i))) return b.mk(.{ .kind = .scalar });
            const md = b.s.mod.declOf(i) orelse {
                b.unsup("value reference");
                return b.mk(.{ .kind = .top });
            };
            const decl = b.s.in.birs[md[0]].decls[md[1]];
            if (decl.params != 0 or b.places().kind(try b.placeOfInst(i)) == .closure) {
                b.unsup("function value");
                return b.mk(.{ .kind = .top });
            }
            return b.mk(.{ .kind = .shared, .a = md[0] *% 65536 +% md[1] });
        },
        .tuple, .list => {
            const items = bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index);
            const ks = try b.arena.alloc(u32, items.len);
            for (items, 0..) |e, k| ks[k] = try evalPending(b, e.int());
            popPending(b, items.len);
            for (ks) |k| if (b.val(k).kind == .bot) return b.mk(.{ .kind = .bot });
            if (b.tag(i) == .tuple) return b.mk(.{ .kind = .con, .a = tuple_key, .kids = try b.mkKids(ks) });
            return b.mk(.{ .kind = .obj, .a = i, .b = 0, .kids = try b.mkKids(ks) });
        },
        .record => {
            const fields = bir.extraSlice(Bir.inlineRange(d), Bir.Field);
            const ks = try b.arena.alloc(u32, fields.len);
            const ranks = try b.arena.alloc(u32, fields.len);
            for (fields, 0..) |f, k| {
                ks[k] = try evalPending(b, f.value.int());
                ranks[k] = Groups.Module.fieldRank(b.s.mod, f.name);
            }
            popPending(b, fields.len);
            for (ks) |k| if (b.val(k).kind == .bot) return b.mk(.{ .kind = .bot });
            // Field order by rank, as the place's steps.
            const order = try b.arena.alloc(u32, fields.len);
            for (order, 0..) |*o, k| o.* = @intCast(k);
            std.mem.sort(u32, order, ranks, struct {
                fn lt(r: []u32, x: u32, y: u32) bool {
                    return r[x] < r[y];
                }
            }.lt);
            const sk = try b.arena.alloc(u32, fields.len);
            const sr = try b.arena.alloc(u32, fields.len);
            for (order, 0..) |o, k| {
                sk[k] = ks[o];
                sr[k] = ranks[o];
            }
            const rset = try b.arena.dupe(u32, sr);
            const start: u32 = @intCast(b.sets.items.len);
            try b.sets.appendSlice(b.arena, rset);
            const sid: u32 = @intCast(b.set_ranges.items.len);
            try b.set_ranges.append(b.arena, .{ .start = start, .len = @intCast(rset.len) });
            return b.mk(.{ .kind = .obj, .a = i, .b = 1, .c = sid, .kids = try b.mkKids(sk) });
        },
        .field_access, .tuple_index => {
            const target = try eval(b, d.lhs);
            const st: Step = if (b.tag(i) == .field_access) try Step.field(&b.st.account, Groups.Module.fieldRank(b.s.mod, @fromBackingInt(d.rhs))) else try Step.index(&b.st.account, d.rhs);
            return projectVal(b, target, .{ .kind = .plain, .a = st.word() }, i);
        },
        .call, .method_call => return evalCall(b, i),
        .let => {
            for (bir.extraSlice(bir.subRange(@fromBackingInt(d.lhs)), Bir.Inst.Index)) |it| try letItem(b, it.int());
            return eval(b, d.rhs);
        },
        .case => return caseOf(b, i),
        else => |t| {
            b.unsup(@tagName(t));
            return b.mk(.{ .kind = .top });
        },
    }
}

fn evalPending(b: *Body, i: u32) Error!u32 {
    const v = try eval(b, i);
    try b.pending.append(b.arena, v);
    return v;
}

fn popPending(b: *Body, n: usize) void {
    b.pending.shrinkRetainingCapacity(b.pending.items.len - n);
}

fn letItem(b: *Body, it: u32) Error!void {
    const d = b.data(it);
    switch (b.tag(it)) {
        .let_def => {
            const def = b.bir().extraData(@fromBackingInt(d.lhs), Bir.LetDef);
            if (def.params_end != def.params_start) {
                b.unsup("local function");
                return;
            }
            const v = try eval(b, d.rhs);
            try setLocal(b, def.local, v, b.bir().insts.items(.main_token)[it]);
        },
        .let_pattern => {
            const v = try eval(b, d.rhs);
            _ = try bind(b, d.lhs, v);
        },
        .let_stmt => _ = try eval(b, d.rhs),
        else => b.unsup("let item"),
    }
}

/// A projection of value `v` by one step: a literal's part, or a position.
fn projectVal(b: *Body, v: u32, step: PStep, inst: u32) Error!u32 {
    _ = inst;
    try b.charge(.inspection, 1);
    const x = b.val(v);
    switch (x.kind) {
        .scalar, .bot, .top, .shared => return v,
        .ref => {
            if (x.c != none) {
                // A family: the step applies to each slot; the position stays.
                const sw: Step = switch (step.kind) {
                    .plain => Step.fromWord(step.a),
                    else => Step.elem,
                };
                var objs: std.ArrayList(u32) = .empty;
                defer objs.deinit(b.s.gpa);
                for (setItems(b, x.c)) |t| {
                    if (step.kind == .slice) {
                        try objs.append(b.s.gpa, t);
                        continue;
                    }
                    const at = (try b.places().extend(b.s.gpa, b.gc(), .from(t), sw)) orelse continue;
                    try objs.append(b.s.gpa, at.int());
                }
                if (objs.items.len == 0) return b.mk(.{ .kind = .scalar });
                return b.mk(.{ .kind = .ref, .a = x.a, .b = x.b, .c = try internSet(b, objs.items) });
            }
            const p = (try childPos(b, x.b, step)) orelse return b.mk(.{ .kind = .scalar });
            return b.mk(.{ .kind = .ref, .a = x.a, .b = p });
        },
        .con => {
            if (step.kind != .plain) return b.mk(.{ .kind = .scalar });
            const st = Step.fromWord(step.a);
            const ks = b.kidsOf(x);
            switch (st.kind) {
                .index => if (x.a == tuple_key and st.payload < ks.len) return ks[st.payload],
                .ctor_arg => {
                    const ca = b.places().ctorArgOf(st);
                    if (ca[0] == x.a and ca[1] < ks.len) return ks[ca[1]];
                },
                else => {},
            }
            return b.mk(.{ .kind = .scalar });
        },
        .obj => {
            const ks = b.kidsOf(x);
            if (x.b == 1) {
                if (step.kind != .plain) return b.mk(.{ .kind = .scalar });
                const st = Step.fromWord(step.a);
                const ranks = setItems(b, x.c);
                for (ranks, 0..) |r, k| if (st.kind == .field and r == st.payload) return ks[k];
                return b.mk(.{ .kind = .scalar });
            }
            switch (step.kind) {
                .front => return if (step.a < ks.len) ks[step.a] else b.mk(.{ .kind = .bot }),
                .back => return if (step.a < ks.len) ks[ks.len - 1 - step.a] else b.mk(.{ .kind = .bot }),
                .slice => {
                    const lo = @min(step.a, ks.len);
                    const hi = ks.len - @min(step.b, ks.len - lo);
                    // A view: the same storage, fewer elements.
                    return b.mk(.{ .kind = .obj, .a = x.a, .b = 0, .kids = try b.mkKids(ks[lo..hi]) });
                },
                .plain => {
                    // `[*]`: any element.
                    if (ks.len == 0) return b.mk(.{ .kind = .bot });
                    if (ks.len == 1) return ks[0];
                    const arms = try b.arena.alloc(u32, ks.len * 2);
                    for (ks, 0..) |k, n| {
                        arms[2 * n] = @intCast(n);
                        arms[2 * n + 1] = k;
                    }
                    return b.mk(.{ .kind = .alt, .a = none - 1 - v, .kids = try b.mkKids(arms) });
                },
            }
        },
        .alt => {
            const ks = b.kidsOf(x);
            var arms: std.ArrayList(u32) = .empty;
            var i: usize = 0;
            while (i < ks.len) : (i += 2) {
                const p = try projectVal(b, ks[i + 1], step, 0);
                if (b.val(p).kind == .bot) continue;
                try arms.appendSlice(b.arena, &.{ ks[i], p });
            }
            if (arms.items.len == 0) return b.mk(.{ .kind = .bot });
            return b.mk(.{ .kind = .alt, .a = x.a, .kids = try b.mkKids(arms.items) });
        },
    }
}

/// Bind pattern `pat` to value `v`; false when it cannot match (a literal
/// built here with another constructor).
fn bind(b: *Body, pat: u32, v: u32) Error!bool {
    try b.charge(.inspection, 1);
    const d = b.data(pat);
    const bir = b.bir();
    const tok = bir.insts.items(.main_token)[pat];
    const x = b.val(v);
    switch (b.tag(pat)) {
        .pat_wild, .pat_int, .pat_char, .pat_string, .pat_unit => return true,
        .pat_var => {
            try setLocal(b, d.lhs, v, tok);
            return true;
        },
        .pat_as => {
            if (!try bind(b, d.lhs, v)) return false;
            try setLocal(b, d.rhs, v, tok);
            return true;
        },
        .pat_ctor, .pat_tuple => {
            const is_tuple = b.tag(pat) == .pat_tuple;
            const key: u32 = if (is_tuple) tuple_key else (Groups.Module.ctorOf(b.s.mod, d.lhs) orelse {
                b.unsup("pattern constructor");
                return true;
            })[0];
            const args = if (is_tuple) bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index) else bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index);
            if (x.kind == .con and x.a != key) return false;
            if (x.kind == .alt) {
                // Each arm that can match.
                const ks = b.kidsOf(x);
                var keep: std.ArrayList(u32) = .empty;
                var i: usize = 0;
                while (i < ks.len) : (i += 2) {
                    const av = b.val(ks[i + 1]);
                    if (av.kind == .con and av.a != key) continue;
                    if (av.kind == .bot) continue;
                    try keep.appendSlice(b.arena, &.{ ks[i], ks[i + 1] });
                }
                if (keep.items.len == 0) return false;
                const nv = try b.mk(.{ .kind = .alt, .a = x.a, .kids = try b.mkKids(keep.items) });
                for (args, 0..) |a, k| {
                    const st: Step = if (is_tuple) try Step.index(&b.st.account, @intCast(k)) else try b.places().ctorStep(b.s.gpa, &b.st.account, key, @intCast(k));
                    const kv = try projectVal(b, nv, .{ .kind = .plain, .a = st.word() }, pat);
                    if (!try bind(b, a.int(), kv)) return false;
                }
                return true;
            }
            for (args, 0..) |a, k| {
                const st: Step = if (is_tuple) try Step.index(&b.st.account, @intCast(k)) else try b.places().ctorStep(b.s.gpa, &b.st.account, key, @intCast(k));
                const kv = try projectVal(b, v, .{ .kind = .plain, .a = st.word() }, pat);
                if (!try bind(b, a.int(), kv)) return false;
            }
            return true;
        },
        .pat_record => {
            for (bir.extraSlice(Bir.inlineRange(d), u32)) |local| {
                const sym = bir.locals[b.locals_start + local].name;
                const st = try Step.field(&b.st.account, Groups.Module.fieldRank(b.s.mod, sym));
                const kv = try projectVal(b, v, .{ .kind = .plain, .a = st.word() }, pat);
                try setLocal(b, local, kv, tok);
            }
            return true;
        },
        .pat_list => {
            const items = bir.extraSlice(Bir.inlineRange(d), Bir.Inst.Index);
            var spread: ?usize = null;
            for (items, 0..) |a, k| if (b.tag(a.int()) == .pat_spread) {
                spread = k;
            };
            if (x.kind == .obj and x.b == 0) {
                const n = b.kidsOf(x).len;
                if (spread == null and n != items.len) return false;
                if (spread != null and n < items.len - 1) return false;
            }
            for (items, 0..) |a, k| {
                const step: PStep = if (spread) |sp| (if (k < sp) PStep{ .kind = .front, .a = @intCast(k) } else if (k == sp) PStep{ .kind = .slice, .a = @intCast(sp), .b = @intCast(items.len - 1 - sp) } else PStep{ .kind = .back, .a = @intCast(items.len - 1 - k) }) else PStep{ .kind = .front, .a = @intCast(k) };
                const kv = try projectVal(b, v, step, pat);
                if (b.val(kv).kind == .bot) return false;
                const inner = if (b.tag(a.int()) == .pat_spread) b.data(a.int()).lhs else a.int();
                if (!try bind(b, inner, kv)) return false;
            }
            return true;
        },
        .pat_spread => return bind(b, d.lhs, v),
        else => {
            b.unsup("pattern");
            return true;
        },
    }
}

fn newCtx(b: *Body, case: u32, arm: u32) Error!u32 {
    try b.charge(.region, 1);
    const id: u32 = @intCast(b.ctxs.items.len);
    try b.ctxs.append(b.arena, .{ .parent = b.cur_ctx, .case = case, .arm = arm, .depth = b.ctxs.items[b.cur_ctx].depth + 1 });
    return id;
}

fn caseOf(b: *Body, i: u32) Error!u32 {
    const d = b.data(i);
    const bir = b.bir();
    const scrut = try eval(b, d.lhs);
    if (b.val(scrut).kind == .bot) return b.mk(.{ .kind = .bot });
    const branches = bir.extraSlice(bir.subRange(@fromBackingInt(d.rhs)), Bir.Inst.Index);
    var arms: std.ArrayList(u32) = .empty;
    const saved = b.cur_ctx;
    for (branches, 0..) |br, k| {
        b.cur_ctx = try newCtx(b, i, @intCast(k));
        defer b.cur_ctx = saved;
        b.point += 1;
        if (!try bind(b, b.data(br.int()).lhs, scrut)) continue;
        const v = try eval(b, b.data(br.int()).rhs);
        if (b.val(v).kind == .bot) continue;
        try arms.appendSlice(b.arena, &.{ @intCast(k), v });
    }
    b.cur_ctx = saved;
    if (arms.items.len == 0) return b.mk(.{ .kind = .bot });
    if (arms.items.len == 2) return arms.items[1];
    return b.mk(.{ .kind = .alt, .a = i, .kids = try b.mkKids(arms.items) });
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

fn calleeName(b: *Body, md: [2]u32) []const u8 {
    const names = b.s.names;
    return std.fmt.allocPrint(b.s.arena, "{s}.{s}", .{ names.module_names[md[0]], names.declName(md[0], md[1]) }) catch "call";
}

fn evalCall(b: *Body, i: u32) Error!u32 {
    const d = b.data(i);
    // A constructor applied.
    if (b.tag(i) == .call) if (Groups.Module.ctorOf(b.s.mod, d.lhs)) |c| {
        var args: std.ArrayList(u32) = .empty;
        defer args.deinit(b.s.gpa);
        try b.s.mod.argsOf(i, &args);
        const ks = try b.arena.alloc(u32, args.items.len);
        for (args.items, 0..) |a, k| ks[k] = try evalPending(b, a);
        popPending(b, ks.len);
        for (ks) |k| if (b.val(k).kind == .bot) return b.mk(.{ .kind = .bot });
        return b.mk(.{ .kind = .con, .a = c[0], .kids = try b.mkKids(ks) });
    };
    var args: std.ArrayList(u32) = .empty;
    defer args.deinit(b.s.gpa);
    try b.s.mod.argsOf(i, &args);
    if (b.tag(i) == .call) switch (b.tag(d.lhs)) {
        .top, .ext_value => {},
        else => {
            b.unsup("call of a function value");
            return b.mk(.{ .kind = .top });
        },
    };
    const vs = try b.arena.alloc(u32, args.items.len);
    for (args.items, 0..) |a, k| vs[k] = try evalPending(b, a);
    popPending(b, vs.len);
    for (vs) |v| if (b.val(v).kind == .bot) return b.mk(.{ .kind = .bot });
    b.point += 1;
    const target = b.s.mod.calledDecl(i);
    const contract = (try calleeContract(b, i, target, args.items)) orelse return b.mk(.{ .kind = .top });
    if (contract.unsupported) |why| {
        b.unsup(try std.fmt.allocPrint(b.s.arena, "callee {s}: {s}", .{ if (target) |t| calleeName(b, t) else "?", why }));
        return b.mk(.{ .kind = .top });
    }
    return instantiate(b, i, contract, vs, args.items, if (target) |t| calleeName(b, t) else "call");
}

/// The callee's contract: a group member's candidate, an earlier
/// declaration's, a word row, an imported one, or harmless.
fn calleeContract(b: *Body, i: u32, target: ?[2]u32, args: []const u32) Error!?*const Contract {
    const s = b.s;
    if (target) |t| {
        const owner = s.in.birs[t[0]];
        const words = owner.ownSlotsV2(owner.decls[t[1]]);
        if (words.len != 0) return try wordContract(b, i, t, words, args);
        if (t[0] == s.in.module) {
            if (s.group.get(t[1])) |c| return c;
            if (s.decls[t[1]]) |st| if (st.contract) |c| return c;
        } else if (try importedContract(b, t)) |c| return c;
    }
    // Harmless: nothing crosses that holds storage.
    var harmless = !b.holdsAt(try b.placeOfInst(i));
    for (args) |a| harmless = harmless and !b.holdsAt(try b.placeOfInst(a));
    if (harmless) {
        const c = try s.arena.create(Contract);
        c.* = .{ .nparams = @intCast(args.len), .res_cross = true, .returns = true };
        return c;
    }
    // A comparison of values (a method with no named target): a read.
    if (target == null and b.tag(i) == .method_call and !b.holdsAt(try b.placeOfInst(i))) {
        const c = try s.arena.create(Contract);
        c.* = .{ .nparams = @intCast(args.len), .res_cross = true, .returns = true };
        return c;
    }
    if (target) |t| {
        b.unsup(try std.fmt.allocPrint(s.arena, "callee {s}: no contract", .{calleeName(b, t)}));
    } else b.unsup("callee: unknown");
    return null;
}

fn importedContract(b: *Body, t: [2]u32) Error!?*const Contract {
    const s = b.s;
    if (s.import_memo.get(t)) |c| return c;
    lockExported();
    const words = exported.get(t);
    unlockExported();
    const w = words orelse {
        try s.import_memo.put(s.gpa, t, null);
        return null;
    };
    try b.charge(.class, @intCast(w.len));
    var dec: Decoder = .{ .words = w, .places = b.places(), .gpa = s.gpa, .arena = s.arena, .account = &b.st.account };
    const c = try s.arena.create(Contract);
    c.* = dec.contract() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadContract => .{ .unsupported = "imported contract does not decode" },
        error.OwnershipLimit => return error.OwnershipLimit,
        error.AccountingInvariant => return error.AccountingInvariant,
        error.ProbeLength => return error.ProbeLength,
    };
    // The round trip: the decoded contract, encoded again in this module's
    // tables, is the same words.
    s.imports_read += 1;
    if (try encodeContract(b.places(), c, s.gpa)) |again| {
        defer s.gpa.free(again);
        if (!std.mem.eql(u32, again, w)) s.imports_mismatched += 1;
    } else s.imports_mismatched += 1;
    try s.import_memo.put(s.gpa, t, c);
    return c;
}

/// A worded callee's row, read against the call site's own places
/// (`ownership-v2.md` §2.13.6, taken as given): `written` a storage write
/// at ε (the other arguments apart from it), `returned` the result is that
/// argument at every slot, `stored` it is the result's `[*]`, `borrowed` a
/// read, `prepended` the result's storage may be fresh.
fn wordContract(b: *Body, i: u32, t: [2]u32, words: []const [2]u32, args: []const u32) Error!*const Contract {
    _ = t;
    const s = b.s;
    const W = Ast.OwnWord;
    const c = try s.arena.create(Contract);
    c.* = .{ .nparams = @intCast(args.len), .returns = true, .from_words = true };
    const rplace = try b.placeOfInst(i);
    c.res_cross = !b.holdsAt(rplace);
    var res: std.AutoHashMapUnmanaged(u32, std.ArrayList(Arr)) = .empty;
    const rroot = try b.places().rootPath(s.gpa, rplace);
    var ws: std.ArrayList(WSlot) = .empty;
    var objs_params: u32 = 0;
    var written: u32 = 0;
    var provenance = false;
    var result_words: u32 = 0;
    for (words) |sw| {
        if (sw[0] == Bir.own_result) {
            result_words = sw[1];
            continue;
        }
        if (sw[0] >= args.len) continue;
        const j = sw[0];
        const known = W.borrowed.bit() | W.written.bit() | W.returned.bit() | W.stored.bit() | W.unused.bit();
        if (sw[1] & ~known != 0) {
            c.unsupported = "word row not read by the slot evaluator";
            return c;
        }
        if (sw[1] & W.written.bit() != 0) {
            try ws.append(s.arena, .{ .j = j, .steps = &.{} });
            written |= @as(u32, 1) << @intCast(j);
        }
        if (sw[1] & W.returned.bit() != 0) {
            provenance = true;
            const proot = try b.places().rootPath(s.gpa, try b.placeOfInst(args[j]));
            try lockWords(b, &res, rroot, proot, j);
        }
        if (sw[1] & W.stored.bit() != 0) {
            provenance = true;
            const proot = try b.places().rootPath(s.gpa, try b.placeOfInst(args[j]));
            if (try b.places().extend(s.gpa, b.gc(), rroot, Step.elem)) |e| try lockWords(b, &res, e, proot, j);
        }
    }
    for (args, 0..) |a, j| if (b.holdsAt(try b.placeOfInst(a))) {
        objs_params |= @as(u32, 1) << @intCast(j);
    };
    if (result_words & ~(W.prepended.bit() | W.fresh.bit() | W.exclusive.bit()) != 0) {
        c.unsupported = "result word not read by the slot evaluator";
        return c;
    }
    if (result_words & (W.prepended.bit() | W.fresh.bit()) != 0) {
        const g = try res.getOrPut(s.arena, rroot.int());
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(s.arena, .{ .kind = .fresh });
        provenance = true;
    }
    if (!c.res_cross and !provenance) {
        // No word says where the result comes from: ⊤ at every slot.
        for (try closureOf(b, rroot)) |sl| {
            const g = try res.getOrPut(s.arena, sl);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(s.arena, .{ .kind = .top });
        }
        c.res_cond = .no;
    } else {
        // Every argument's objects, each once, all apart.
        var rc: Cond = .{};
        for (args, 0..) |a, k| if ((objs_params >> @intCast(k)) & 1 != 0) {
            const root = try b.places().rootPath(s.gpa, try b.placeOfInst(a));
            for (try closureOf(b, root)) |sl| rc = rc.conj(.{ .sel = try s.arena.dupe(u64, &.{occ(@intCast(k), try internSteps(s, try stepsOf(b, .from(sl))))}) });
        };
        c.res_cond = rc;
    }
    // A written argument's storage is apart from every other argument.
    var req: Cond = .{};
    var j: u32 = 0;
    while (j < args.len) : (j += 1) {
        if ((written >> @intCast(j)) & 1 == 0) continue;
        var k: u32 = 0;
        while (k < args.len) : (k += 1) if (k != j and (objs_params >> @intCast(k)) & 1 != 0) {
            // Only a part of the same kind as the written storage can be it.
            const jkind = b.places().kind(try b.placeOfInst(args[j]));
            const kroot = try b.places().rootPath(s.gpa, try b.placeOfInst(args[k]));
            var any = false;
            for (try closureOf(b, kroot)) |sl| {
                if (b.places().kind(b.places().pathPlace(.from(sl))) != jkind and b.places().kind(b.places().pathPlace(.from(sl))) != .@"var") continue;
                any = true;
                req = req.conj(.{ .sel = try s.arena.dupe(u64, &.{occ(@intCast(k), try internSteps(s, try stepsOf(b, .from(sl))))}) });
            }
            if (any) req = req.conj(.{ .sel = try s.arena.dupe(u64, &.{occ(j, try internSteps(s, &.{}))}) });
        };
    }
    c.req = req;
    c.writes = ws.items;
    var slots: std.ArrayList(ResSlot) = .empty;
    var it = res.iterator();
    while (it.next()) |e| {
        std.mem.sort(Arr, e.value_ptr.items, {}, arrLess);
        const path: PathId = .from(e.key_ptr.*);
        try slots.append(s.arena, .{ .steps = try stepsOf(b, path), .var_leaf = b.places().kind(b.places().pathPlace(path)) == .@"var", .arrs = e.value_ptr.items });
    }
    std.mem.sort(ResSlot, slots.items, {}, struct {
        fn lt(_: void, x: ResSlot, y: ResSlot) bool {
            return std.mem.order(u32, x.steps, y.steps) == .lt;
        }
    }.lt);
    c.res = slots.items;
    return c;
}

fn lockWords(b: *Body, res: *std.AutoHashMapUnmanaged(u32, std.ArrayList(Arr)), q: PathId, p: PathId, j: u32) Error!void {
    // Lockstep from the result slot and the parameter's root, every slot.
    var stack: std.ArrayList([2]PathId) = .empty;
    defer stack.deinit(b.s.gpa);
    var seen: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer seen.deinit(b.s.gpa);
    try stack.append(b.s.gpa, .{ q, p });
    while (stack.pop()) |pair| {
        if ((try seen.getOrPut(b.s.gpa, .{ pair[0].int(), pair[1].int() })).found_existing) continue;
        try b.charge(.label, 1);
        if (b.isObj(pair[0])) {
            const g = try res.getOrPut(b.s.arena, pair[0].int());
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(b.s.arena, .{ .kind = .param, .j = j, .steps = try stepsOf(b, pair[1]) });
        }
        const steps = b.places().steps(b.places().pathPlace(pair[0]));
        for (steps.steps) |stp| {
            const q2 = (try b.places().extend(b.s.gpa, b.gc(), pair[0], stp)) orelse continue;
            const p2 = (try b.places().extend(b.s.gpa, b.gc(), pair[1], stp)) orelse continue;
            try stack.append(b.s.gpa, .{ q2, p2 });
        }
    }
}

/// A call at a site: its root, its per-slot instantiation built once, its
/// demands.
fn instantiate(b: *Body, i: u32, c: *const Contract, vs: []const u32, arg_insts: []const u32, op: []const u8) Error!u32 {
    const s = b.s;
    b.st.stats.calls += 1;
    try b.charge(.class, 1);
    const aplaces = try b.arena.alloc(PlaceId, arg_insts.len);
    for (arg_insts, aplaces) |a, *pl| pl.* = try b.placeOfInst(a);
    // Demands, recorded now and resolved when every use is known.
    if (c.writes.len != 0) {
        var targets: std.ArrayList(Target) = .empty;
        for (c.writes) |w| {
            if (w.j >= vs.len) continue;
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(s.gpa);
            try project(b, vs[w.j], aplaces[w.j], w.steps, 0, &ls);
            try targets.append(b.arena, .{ .j = w.j, .steps = w.steps, .leaves = try b.arena.dupe(u32, ls.items), .arg_inst = arg_insts[w.j] });
        }
        const req = try instSel(b, c.req, vs, aplaces);
        b.st.stats.demands += 1;
        try b.demands.append(b.arena, .{ .inst = i, .point = b.point, .ctx = b.cur_ctx, .pending = try b.arena.dupe(u32, b.pending.items), .targets = targets.items, .req = req, .op = op, .primitive = c.from_words });
    }
    if (c.res_cross) return b.mk(.{ .kind = .scalar });
    if (!c.returns) return b.mk(.{ .kind = .bot });
    const rplace = try b.placeOfInst(i);
    const rpath = try b.places().rootPath(s.gpa, rplace);
    const ci: u32 = @intCast(b.calls.items.len);
    const root: u32 = @intCast(b.roots.items.len);
    try b.calls.append(b.arena, .{ .inst = i, .contract = c, .args = try b.arena.dupe(u32, vs), .places = aplaces, .root = root });
    try b.roots.append(b.arena, .{ .kind = .call, .a = ci, .place = rplace, .path = rpath, .pos = none });
    const rp = try rootPos(b, root);
    b.roots.items[root].pos = rp;
    // The instantiation, once at this site: per caller result slot, the
    // callee's arrivals projected onto the arguments.
    var map: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    for (c.res) |rs| {
        const slot = (try replay(b, rpath, rs.steps)) orelse continue;
        for (rs.arrs) |a| {
            var ls: std.ArrayList(u32) = .empty;
            defer ls.deinit(s.gpa);
            switch (a.kind) {
                .param => if (a.j < vs.len) try project(b, vs[a.j], aplaces[a.j], a.steps, 0, &ls),
                .fresh => try ls.append(s.gpa, try mkLeaf(b, .{ .kind = .callfresh, .root = root })),
                .top => try ls.append(s.gpa, try mkLeaf(b, .{ .kind = .top })),
                .shared => try ls.append(s.gpa, try mkLeaf(b, .{ .kind = .top })),
            }
            try addInst(b, &map, slot, ls.items);
            // Below a callee's type variable: the caller's deeper slots, the
            // same arrival extended by the same steps.
            if (rs.var_leaf) {
                var stack: std.ArrayList(struct { PathId, []const u32 }) = .empty;
                defer stack.deinit(s.gpa);
                var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer seen.deinit(s.gpa);
                try stack.append(s.gpa, .{ slot, &.{} });
                while (stack.pop()) |e| {
                    if ((try seen.getOrPut(s.gpa, e[0].int())).found_existing) continue;
                    try b.charge(.inspection, 1);
                    if (e[1].len != 0 and b.isObj(e[0])) {
                        var ls2: std.ArrayList(u32) = .empty;
                        defer ls2.deinit(s.gpa);
                        switch (a.kind) {
                            .param => if (a.j < vs.len) {
                                const st2 = try b.arena.alloc(u32, a.steps.len + e[1].len);
                                @memcpy(st2[0..a.steps.len], a.steps);
                                @memcpy(st2[a.steps.len..], e[1]);
                                try project(b, vs[a.j], aplaces[a.j], st2, 0, &ls2);
                            },
                            else => try ls2.append(s.gpa, try mkLeaf(b, .{ .kind = .top })),
                        }
                        try addInst(b, &map, e[0], ls2.items);
                    }
                    const steps = b.places().steps(b.places().pathPlace(e[0]));
                    for (steps.steps) |stp| {
                        const nx = (try b.places().extend(s.gpa, b.gc(), e[0], stp)) orelse continue;
                        const ext = try b.arena.alloc(u32, e[1].len + 1);
                        @memcpy(ext[0..e[1].len], e[1]);
                        ext[e[1].len] = stp.word();
                        try stack.append(s.gpa, .{ nx, ext });
                    }
                }
            }
        }
    }
    var it = map.iterator();
    while (it.next()) |e| {
        const start: u32 = @intCast(b.leaf_lists.items.len);
        try b.leaf_lists.appendSlice(b.arena, e.value_ptr.items);
        try b.calls.items[ci].inst_map.put(b.arena, e.key_ptr.*, .{ .start = start, .len = @intCast(e.value_ptr.items.len) });
    }
    return b.mk(.{ .kind = .ref, .a = root, .b = rp });
}

fn addInst(b: *Body, map: *std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)), slot: PathId, ls: []const u32) Error!void {
    try b.charge(.edge, @intCast(@max(1, ls.len)));
    b.st.stats.substitutions += ls.len;
    const g = try map.getOrPut(b.arena, slot.int());
    if (!g.found_existing) g.value_ptr.* = .empty;
    for (ls) |l| {
        const found = for (g.value_ptr.items) |x| {
            if (x == l) break true;
        } else false;
        if (!found) try g.value_ptr.append(b.arena, l);
    }
}

// ---------------------------------------------------------------------------
// Demands
// ---------------------------------------------------------------------------

fn compatible(b: *Body, c1: u32, c2: u32) Error!bool {
    var a = c1;
    var c = c2;
    try b.charge(.region, 1);
    while (b.ctxs.items[a].depth > b.ctxs.items[c].depth) a = b.ctxs.items[a].parent;
    while (b.ctxs.items[c].depth > b.ctxs.items[a].depth) c = b.ctxs.items[c].parent;
    while (a != c) {
        const pa = b.ctxs.items[a];
        const pc = b.ctxs.items[c];
        if (pa.parent == pc.parent and pa.case == pc.case) return false;
        a = pa.parent;
        c = pc.parent;
    }
    return true;
}

fn localName(b: *Body, local: u32) []const u8 {
    const bir = b.bir();
    const sym = bir.locals[b.locals_start + local].name;
    return b.s.names.interner.slice(bir.symbol(sym));
}

fn posText(b: *Body, tok: u32) Message.Position {
    return b.s.names.position(b.s.names.ctx, b.s.in.module, tok);
}

const Holder = struct { v: u32, local: u32, use_tok: u32, pending: bool };

fn resolveDemands(b: *Body) Error!void {
    const s = b.s;
    for (b.demands.items) |dm| {
        try b.charge(.demand, 1);
        // Live locals at the demand: bound before it, used after it in an
        // arm that runs with it.
        var holders: std.ArrayList(Holder) = .empty;
        defer holders.deinit(s.gpa);
        for (dm.pending) |pv| try holders.append(s.gpa, .{ .v = pv, .local = none, .use_tok = 0, .pending = true });
        var it = b.locals.iterator();
        while (it.next()) |e| {
            const local = e.key_ptr.*;
            const bound = b.bound_at.get(local) orelse continue;
            if (bound >= dm.point) continue;
            var later: ?Use = null;
            for (b.uses.items) |u| {
                try b.charge(.use, 1);
                if (u.local != local or u.point <= dm.point) continue;
                if (!try compatible(b, u.ctx, dm.ctx)) continue;
                if (later == null or u.point < later.?.point) later = u;
            }
            if (later) |u| try holders.append(s.gpa, .{ .v = e.value_ptr.*, .local = local, .use_tok = u.token, .pending = false });
        }
        // Holders in a canonical order (rule 5): pending first, then by local.
        std.mem.sort(Holder, holders.items, {}, struct {
            fn lt(_: void, x: Holder, y: Holder) bool {
                if (x.pending != y.pending) return x.pending;
                return x.local < y.local;
            }
        }.lt);
        const tok = b.bir().insts.items(.main_token)[dm.inst];
        const at = posText(b, tok);
        for (dm.targets) |tg| {
            var verdict: []const u8 = "";
            var cond: Cond = dm.req;
            if (!dm.req.ok) verdict = "rejected disjoint: the callee needs this argument apart (from its other paths or the other arguments), and it may not be";
            // Known: every written object has a provenance.
            var full: std.ArrayList(u32) = .empty;
            defer full.deinit(s.gpa);
            for (tg.leaves) |l| try expandFull(b, l, &full, 0);
            var kind: enum { fresh, call, param } = .fresh;
            for (full.items) |f| {
                const l = b.leaves.items[f];
                switch (l.kind) {
                    .top => if (verdict.len == 0) {
                        verdict = "rejected unknown: what it writes may be any object";
                    },
                    .shared => if (verdict.len == 0) {
                        verdict = "rejected shared: it writes a top-level value";
                    },
                    .callfresh => if (kind == .fresh) {
                        kind = .call;
                    },
                    .ref => if (b.roots.items[l.root].kind == .param) {
                        kind = .param;
                    } else if (verdict.len == 0) {
                        verdict = "rejected unknown";
                    },
                    .site => {},
                }
            }
            // Dead: no live holder holds a written object.
            if (verdict.len == 0) holders: for (holders.items) |h| {
                var hl: std.ArrayList(u32) = .empty;
                defer hl.deinit(s.gpa);
                try leavesOf(b, h.v, 0, &hl);
                for (hl.items) |x| for (tg.leaves) |t| {
                    const o = try overlap(b, x, t, true);
                    if (o.yes) {
                        verdict = if (h.pending) "rejected held-operand: a pending operand holds it" else blk: {
                            const up = posText(b, h.use_tok);
                            break :blk try std.fmt.allocPrint(s.arena, "rejected alias: {s} holds it and is read at {d}:{d}", .{ localName(b, h.local), up.line, up.col });
                        };
                        break :holders;
                    }
                    cond = cond.conj(o.cond);
                };
            };
            if (verdict.len == 0 and !cond.ok) verdict = "rejected exclusive: the separation it rests on does not hold";
            if (s.mode == .copy) verdict = "rejected copy (copy-semantics control)";
            const accepted = verdict.len == 0;
            if (accepted) {
                b.req = b.req.conj(cond);
                // A write of the caller's objects is the declaration's write.
                for (full.items) |f| {
                    const l = b.leaves.items[f];
                    if (l.kind != .ref or b.roots.items[l.root].kind != .param) continue;
                    for (setItems(b, l.slots)) |sl| try b.writes.append(s.arena, .{ .j = b.roots.items[l.root].a, .steps = try stepsOf(b, .from(sl)) });
                }
            }
            const arg_text: []const u8 = if (b.tag(tg.arg_inst) == .local) localName(b, b.data(tg.arg_inst).lhs) else "<expr>";
            var buf: std.Io.Writer.Allocating = .init(s.arena);
            const w = &buf.writer;
            w.print("  {d}:{d} {s} {s}", .{ at.line, at.col, dm.op, arg_text }) catch return error.OutOfMemory;
            if (tg.steps.len != 0) try stepsText(s, w, tg.steps);
            if (accepted) {
                w.print(": accepted {t}", .{kind}) catch return error.OutOfMemory;
                if (cond.sel.len != 0 or cond.all) {
                    w.writeAll(" (") catch return error.OutOfMemory;
                    try condText(w, cond);
                    w.writeAll(")") catch return error.OutOfMemory;
                }
            } else w.print(": {s}", .{verdict}) catch return error.OutOfMemory;
            if (!b.final) continue;
            try b.st.lines.append(s.arena, buf.written());
            if (dm.primitive) try b.st.channel.append(s.arena, .{ .inst = dm.inst, .refused = !accepted, .callers = kind == .param });
        }
    }
}
