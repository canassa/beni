//! The ownership checker in report mode (`docs/design/ownership-checker.md`,
//! normative; the argument is the thesis `docs/thesis/ownership/`).
//!
//! For every *demand* — a `core/List` writer, a list construction with a
//! spread, a `++` chain on lists (§3), and from slice 2 a call whose callee's
//! summary writes a parameter (§16.4) — it decides whether the list the
//! demand would write in place is *unique at the site*: no holder of it is
//! read afterwards (thesis §3.3). It changes nothing a program does: it runs
//! only under `beni dump --stage=ownership`, after the checker, and prints
//! one line per demand (§9, §16.11).
//!
//! **The walk** (§2.1) is BIR's expression tree in evaluation order —
//! callee, arguments left to right, then the call — with a point per
//! consuming instruction. Abstract values map paths to abstract cells (§4);
//! a variable is used at the instruction that consumes it (§7.1); a `case`
//! arm is a branch context, and a lambda's body is a frame of its own (§7.2,
//! §7.3).
//!
//! **Summaries** (§16): every top-level value with parameters has one, read
//! off its body after the walk, and every lambda a *class* read off its
//! frame. A call through a summary uses only the paths the callee touches,
//! demands at the call what the callee writes, escapes what it keeps, checks
//! the callbacks it is handed against what it supplies them, and returns
//! its result instantiated. A recursive group is solved by an optimistic
//! fixpoint with a join, then validated (§16.6). Summaries are computed on
//! demand (§16.9). `core/List`'s primitives carry asserted rows (§16.8).
//! Calls with no summary are conservative, exactly as §6.1 says.
//!
//! **Determinism** (§10): modules in the order the caller gives (path
//! order), declarations in source order, every id assigned in the walk;
//! nothing printed is an id, and every fact is printed in text order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Check = @import("../check/Check.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Scc = @import("../check/Scc.zig");
const SourceStore = @import("../SourceStore.zig");
const Token = @import("../lex/Token.zig");
const Ast = @import("../parse/Ast.zig");
const summary_bytes = @import("summary_bytes.zig");
const Profile = @import("../Profile.zig");

const Inst = Bir.Inst;
const Symbol = InternPool.Symbol;
const Var = TypeStore.Var;
const TypeId = TypeStore.TypeId;

const Ownership = @This();

pub const none: u32 = std.math.maxInt(u32);

/// k: the path cut (§4.1, thesis §3.1).
pub const k_limit: u32 = 8;
/// Depth of a walk over a type before it answers conservatively.
const type_depth: u32 = 16;
/// §16.7: the most entries a summary's component may hold.
pub const width_cap: usize = 64;
/// §16.6: the backstop on a recursive group's rounds.
pub const round_cap: u32 = 32;
/// §16.7: the most `returns owned` atoms a summary's `owned` bits use.
pub const atom_cap: u32 = 8;
/// §20.4: a value this wide is indexed by its first step when projected.
const wide_index: usize = 256;

const WideIndex = struct {
    roots: std.ArrayList(Entry) = .empty,
    any: std.ArrayList(Entry) = .empty,
    by: std.AutoHashMapUnmanaged([2]u32, std.ArrayList(Entry)) = .empty,
};

/// §20.4: the widest value whose deep condition is computed pair by pair.
const deep_cap: usize = 256;
/// How deep a callback's result is instantiated through another's.
const inst_depth: u32 = 4;

pub const Position = struct { line: u32, col: u32 };

pub const Positions = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, module: u32, token: u32) Position,
};

pub const Input = struct {
    gpa: Allocator,
    graph: *const Graph,
    /// Per module index.
    birs: []const *const Bir,
    provenance: []const Interface.Provenance,
    /// Per module index; shorter when a module was not checked.
    dispatch: []const Dispatch,
    /// Per module index: the kept check tables; shorter, or with an empty
    /// `inst_type`, when a module was not checked.
    modules: []Check.Module,
    types: *const Types,
    interner: *const InternPool.Global,
    /// Per module index.
    module_names: []const []const u8,
    packages: []const SourceStore.Package,
    /// Per module index: the file's token tags.
    spans: []const Token.Spans,
    /// Per module index: the file's bytes, for a message's places (§28.6);
    /// shorter when the caller has none.
    sources: []const []const u8 = &.{},
    positions: Positions,
    /// Per module index: the name of the platform package it belongs to
    /// (the chain layer's manifest `"name"`), empty for any other; what
    /// the entry rows are keyed by (§20.2). Shorter when no chain is known.
    platform_names: []const []const u8 = &.{},
    /// Per module index: whether its platform package's own manifest says
    /// `"lists": "in-place"` (§28.2) — what the direct entry row is keyed by
    /// (§20.2 as amended). Shorter when no chain is known.
    in_place: []const bool = &.{},
    /// Per module index: the summary block (§28.4) of a module the run did
    /// not check, which the pass reads in place of a walk. Shorter, or null,
    /// for a module with none.
    blocks: []const ?[]const u8 = &.{},
    /// §28.3: a checked module is read by another module through its block,
    /// written and read back, as an installed one is — so that the verdicts
    /// are the ones a build that installed it would give, and the block's
    /// format is exercised by every report.
    seal: bool = true,
    /// Where each reported module's walk and the blocks' reading are timed
    /// (`ownership_module`, `ownership_blocks`), on thread 0: the pass is
    /// serial.
    profile: ?*Profile = null,
    /// Test-only (`--ownership-flips`, §24.6): one declaration's words read
    /// with some flipped, to show that the fixture pinning them depends on
    /// them.
    flip: ?Flip = null,
};

/// §24.6: a declaration's ownership words with some changed, `Module.name`
/// and per edit a position (a parameter from 0, or `Bir.own_result`), the
/// word taken away and the word put there — either may be none.
pub const Flip = struct {
    module: []const u8,
    decl: []const u8,
    edits: []const Edit,

    pub const Edit = struct { slot: u32, from: ?Ast.OwnWord, to: ?Ast.OwnWord };

    /// `Module.name:<slot>:<from>><to>[+<slot>:<from>><to>…]`, a slot a
    /// parameter from 1 or `res`, a word or `-`; null when malformed.
    pub fn parse(gpa: Allocator, text: []const u8) Allocator.Error!?Flip {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const name = text[0..colon];
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        var edits: std.ArrayList(Edit) = .empty;
        var parts = std.mem.splitScalar(u8, text[colon + 1 ..], '+');
        while (parts.next()) |part| {
            const c = std.mem.indexOfScalar(u8, part, ':') orelse return null;
            const gt = std.mem.indexOfScalar(u8, part, '>') orelse return null;
            if (gt < c) return null;
            const slot: u32 = if (std.mem.eql(u8, part[0..c], "res")) Bir.own_result else (std.fmt.parseUnsigned(u32, part[0..c], 10) catch return null) -% 1;
            const word = struct {
                fn f(t: []const u8) error{Bad}!?Ast.OwnWord {
                    if (std.mem.eql(u8, t, "-")) return null;
                    return std.meta.stringToEnum(Ast.OwnWord, t) orelse error.Bad;
                }
            }.f;
            const from = word(part[c + 1 .. gt]) catch return null;
            const to = word(part[gt + 1 ..]) catch return null;
            try edits.append(gpa, .{ .slot = slot, .from = from, .to = to });
        }
        return .{ .module = name[0..dot], .decl = name[dot + 1 ..], .edits = edits.items };
    }
};

/// §8.2; `entry` §20.6.
pub const Accept = enum { fresh, call, param, callback_param, once, entry };

/// §8.3, in its order, then §16.11's.
pub const Cause = enum {
    unknown,
    escaped,
    top_level,
    captured_edit,
    disjoint,
    held_operand,
    later_use,
    alias,
    captured,
    element,
    call,
    supply,
    need,
    limit,
    /// §18.4: a write that needs exclusive contents where they may share.
    exclusive,
    /// §18.8: a closure that writes what it captured may run more than once.
    once,
    /// §20.5: a message's payload may still be held by its sender.
    payload,
    /// §20.3: `view` and `subscriptions` receive the model to read only.
    read_only,
    /// §20.2: a template platform keeps the model it hands `update`.
    platform,

    pub fn text(c: Cause) []const u8 {
        return switch (c) {
            .unknown => "unknown",
            .escaped => "escaped",
            .top_level => "top-level",
            .captured_edit => "captured-edit",
            .disjoint => "disjoint",
            .held_operand => "held-operand",
            .later_use => "later-use",
            .alias => "alias",
            .captured => "captured",
            .element => "element",
            .call => "call",
            .supply => "supply",
            .need => "need",
            .limit => "limit",
            .exclusive => "exclusive",
            .once => "once",
            .payload => "payload",
            .read_only => "read-only",
            .platform => "platform",
        };
    }

    /// The default derivation of a cause (thesis §8.4); `supply` is
    /// decided per rejection (§16.11).
    pub fn approximate(c: Cause) bool {
        return switch (c) {
            .unknown, .escaped, .captured_edit, .element, .call, .limit, .exclusive, .payload => true,
            else => false,
        };
    }
};

pub const Verdict = union(enum) {
    accepted: Accept,
    /// An obligation slice 2 does not discharge (§16.5).
    pending,
    rejected: Cause,
};

/// One line of the report (§9.1, §16.11).
pub const Demand = struct {
    position: Position,
    /// `construction`, `++`, `List.<writer>`, `call M.f`, or `value`.
    op: []const u8,
    base: []const u8,
    verdict: Verdict,
    /// For a rejection or a pending line, the reason after the cause.
    detail: []const u8,
    /// The summary that decided it, printed in parentheses.
    note: []const u8 = "",
    /// An acceptance that rests on a callee with no summary (§15 decision 2).
    assumed: bool = false,
    /// A rejection's derivation.
    approx: bool = false,
    /// §28.6: the places a message names, as tokens of the module — `none`
    /// where there is none. The demand's own token; the first and last token
    /// of the edit, and of its base when the base is written in the source.
    token: u32 = none,
    span: [2]u32 = .{ none, none },
    base_span: [2]u32 = .{ none, none },
    /// The holder a Dead failure names (§8.3): its name, where it was bound,
    /// and the use after the demand that keeps it live.
    holder: []const u8 = "",
    keep_token: u32 = none,
    /// The read: the variable path as written, when it is one, else its
    /// consumer.
    read_span: [2]u32 = .{ none, none },
    /// The call an approximate holder holds it through, or the operand a
    /// `held-operand` failure waits on.
    via_token: u32 = none,
    /// `top-level`: the top-level value, `(module, declaration, 1 when the
    /// list is the value itself)`.
    top: ?[3]u32 = null,
};

/// One summary line (§16.11).
pub const SummaryLine = struct { text: []const u8 };

pub const ModuleReport = struct {
    module: u32,
    checked: bool,
    demands: []const Demand,
    summaries: []const SummaryLine = &.{},
};

// ---------------------------------------------------------------------------
// Summaries (§16.2)
// ---------------------------------------------------------------------------

pub const bit_r: u8 = 1;
pub const bit_a: u8 = 2;
pub const bit_e: u8 = 4;
pub const bit_w: u8 = 8;
/// With `bit_w`: some demand writes the path through exact steps only; a
/// W without it was derived through an approximate one (thesis §8.4).
pub const bit_x: u8 = 16;
/// §18.6: escaped, and only by a function value handed to JavaScript that
/// captured it — Change 5's words would decide it; printed `J`.
pub const bit_j: u8 = 64;
/// With `bit_w`: §23.2, a send's write — every cell at or below the path is
/// given up, not only the one at it; printed `S` (`s` when approximate).
pub const bit_d: u8 = 128;

pub const UseEntry = struct { param: u32, path: u32, bits: u8 };

pub const ProvKind = enum(u8) { param, fresh, esc, shared, top, cb, env, klass };

/// A provenance (thesis §3.7's `Prov`). `param`: `a` the parameter's index
/// from 0, `path` its path. `fresh`/`esc`: `a` the number, from 1 (0 in a
/// supply, where it is not compared). `shared`: `a` the module, `b` the
/// declaration, `path` the path in it. `cb`: `a` the function parameter's
/// index. `env` (a lambda's class only): `a` the captured local, `path`.
pub const Prov = struct {
    kind: ProvKind,
    a: u32 = 0,
    b: u32 = 0,
    path: u32 = 0,
    /// `param`, in a supply or the traversal primitive's result: an element
    /// taken out of its container by a destructive read (§18.5).
    taken: bool = false,

    fn eql(x: Prov, y: Prov) bool {
        return x.kind == y.kind and x.a == y.a and x.b == y.b and x.path == y.path and x.taken == y.taken;
    }

    fn less(x: Prov, y: Prov) bool {
        if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
        if (x.a != y.a) return x.a < y.a;
        if (x.b != y.b) return x.b < y.b;
        if (x.path != y.path) return x.path < y.path;
        return @intFromBool(x.taken) < @intFromBool(y.taken);
    }
};

/// §18.2–§18.3: an atom of an exclusivity condition, over a summary's
/// parameters. `excl a`: `a` is deeply exclusive. `sep a b`: `a` and `b`
/// share no cell; `sep cb_j cb_j`: two calls of `π_j` return none in common.
/// `keep a b` (`focus`'s row only): the callback `a`, handed an element of
/// `b` destructively, returns what keeps `b` exclusive (the thesis's "keeps
/// shape").
/// `spine`, `sep_spine` and `keep_spine` state the corresponding conditions
/// for the containers at the named paths, without owning their contents
/// (the dated fold-invariant amendment).
pub const XAtom = struct {
    kind: enum(u8) { excl, sep, keep, spine, keep_spine, sep_spine },
    a: Prov,
    b: Prov = .{ .kind = .top, .a = 0 },

    fn eql(x: XAtom, y: XAtom) bool {
        return x.kind == y.kind and x.a.eql(y.a) and x.b.eql(y.b);
    }

    fn less(x: XAtom, y: XAtom) bool {
        if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
        if (!x.a.eql(y.a)) return x.a.less(y.a);
        return x.b.less(y.b);
    }
};

/// §18.2: an exclusivity condition, as a summary states it.
pub const XSum = struct {
    /// 0: holds, given `atoms`; 1: fails, approximately; 2: fails, exactly.
    no: u8 = 0,
    atoms: []const XAtom = &.{},

    fn eql(x: XSum, y: XSum) bool {
        if (x.no != y.no or x.atoms.len != y.atoms.len) return false;
        for (x.atoms, y.atoms) |a, b| if (!a.eql(b)) return false;
        return true;
    }
};

pub const ResEntry = struct { path: u32, prov: Prov, approx: bool = false, xc: XSum = .{}, sc: XSum = .{} };

pub const SupplyEntry = struct {
    fun: u32,
    k: u32,
    path: u32,
    prov: Prov,
    owned: bool,
    /// When borrowed: whether only an approximate step made it so (an
    /// element, a level of a recursive value, a value from JavaScript).
    approx: bool = false,
    /// The condition of what is supplied (§18.3).
    xc: XSum = .{},
};

pub const Calls = enum(u8) { zero, once, many };

pub const FunFacts = struct {
    param: u32,
    calls: Calls = .zero,
    need: bool = false,
    seen: bool = true,
    /// §23.3: the callee hands this parameter, as its parameter `send`, a
    /// function that sends what it is given to `update`; `none` otherwise.
    send: u32 = none,
};

pub const Limit = enum(u8) { none, width, rounds };

/// §24.9: a function value a summary's result carries — a lambda written in
/// the body — with its class, and what each of its captures held, in the
/// summary's vocabulary. Carried only when the class writes nothing,
/// escapes nothing and relies on nothing, so calling it where it arrives
/// needs only its result and its reads.
pub const Carried = struct {
    sum: *const Summary,
    /// Per capture `(local, path)` of the lambda: the provenances of what
    /// the local held there, each at its path below.
    binds: []const Bind,
    /// The declaration's function parameters the lambda calls (its class's
    /// `cb_j` with `b` 1, §18.9): called through what the caller passed.
    cb_js: []const u32 = &.{},

    pub const Bind = struct { local: u32, path: u32, provs: []const ResEntry };
};

pub const Summary = struct {
    params: u32,
    uses: []const UseEntry = &.{},
    res: []const ResEntry = &.{},
    supply: []const SupplyEntry = &.{},
    /// One per function-typed parameter, by parameter index.
    funs: []const FunFacts = &.{},
    limit: Limit = .none,
    asserted: bool = false,
    /// Too wide for the cap, it was coarsened (§16.7): some parameters are
    /// tracked whole and some result paths cut, each such fact approximate.
    coarse: bool = false,
    /// §18.4: the exclusivity the body relied on, which callers discharge.
    xreq: []const XAtom = &.{},
    /// §18.8, a class only: it writes what it captured, so it runs once.
    once: bool = false,
    /// §24: read from the declaration's ownership words, not off a body.
    words: bool = false,
    /// §24.9: the function slots — a function stored at a path of a
    /// parameter, `(param, path)` — whose facts `funs`, `supply` and a
    /// `cb` provenance name by index `params + k`.
    slots: []const [2]u32 = &.{},
    /// §24.9: the function values the result carries with their classes,
    /// named by a `klass` provenance.
    klasses: []const Carried = &.{},

    fn funOf(s: *const Summary, j: u32) ?FunFacts {
        for (s.funs) |f| if (f.param == j) return f;
        return null;
    }

    fn writesAny(s: *const Summary) bool {
        if (s.once) return true;
        for (s.uses) |u| if (u.bits & bit_w != 0) return true;
        return false;
    }
};

const Slot = struct {
    state: enum { none, computing, done } = .none,
    sum: Summary = .{ .params = 0 },
    /// In a module the run reports on: the lines of the walk the summary was
    /// last read off, which ran against the final assumptions (§16.6's
    /// validation walk), so the report need not walk the body again.
    lines: ?[]const Demand = null,
    /// Read back through its block once another module asked for it (§28.3).
    sealed: bool = false,
};

const Groups = struct {
    /// Per declaration: its group.
    of: []u32,
    order: []u32,
    starts: []u32,
    recursive: []bool,
};

in: Input,
/// Owns everything a report holds.
out: std.heap.ArenaAllocator,
/// Owns every summary.
keep: std.heap.ArenaAllocator,
paths: Paths,
/// Per `TypeId`, a column: null until computed.
nominal: []?NominalFacts = &.{},
ctor_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
/// Per module: the summary of each declaration, allocated on first use.
slots: []?[]Slot = &.{},
groups: []?Groups = &.{},
/// Per module: whether the run reports on it.
report_for: []bool = &.{},
builder_id: ?TypeId = null,
/// §26.2: core `Result`'s type and its `Err` constructor's id, for `?`;
/// `ty` is `none` when the run has no core `Result`.
result_err: ?ResultErr = null,
/// Per constructor id: its type's `(module, declaration)`, or none.
ctor_type: std.ArrayList(u64) = .empty,
/// Per constructor id: its `(module, index)`, for printing.
ctor_key: std.ArrayList(u64) = .empty,
/// Per type `(module, declaration)`: whether it is recursive.
recursive_types: std.AutoHashMapUnmanaged(u64, bool) = .empty,
/// Memos of path arithmetic, which the walk repeats (§18.11).
concat_memo: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
/// Per `(module, type variable)`: whether a value of the type may hold a cell.
tracked_memo: std.AutoHashMapUnmanaged(u64, bool) = .empty,
/// Per `(module, declaration)`: its qualified name.
names_memo: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
/// Per depth of nested walks: an arena reused from walk to walk.
walk_arenas: [16]?std.heap.ArenaAllocator = @splat(null),
walk_depth: u32 = 0,
/// The summary `summaryText` prints, so that a slot's `cb` names its path.
text_sum: ?*const Summary = null,
/// `--ownership-flips` (§24.6): whether the flip met every word it takes away.
flip_applied: bool = false,
/// Per module: its block read (§28.4), or null; computed on first use.
decoded: []?summary_bytes.Block = &.{},
/// Per module: 0 untouched, 1 its block could not be read, 2 sealed (§28.3).
block_state: []u8 = &.{},
/// The module of the walk under way, outermost first: a summary another
/// module asks for is read through the block (§28.3).
walking: u32 = none,
/// Nanoseconds spent reading blocks, for `ownership_blocks`.
block_ns: u64 = 0,
/// `(package, dotted name)` → module index, for reading a block.
module_by_name: std.StringHashMapUnmanaged(u32) = .empty,

pub fn init(in: Input) Ownership {
    return .{ .in = in, .out = .init(in.gpa), .keep = .init(in.gpa), .paths = .{} };
}

pub fn deinit(o: *Ownership) void {
    o.out.deinit();
    o.keep.deinit();
    o.paths.deinit(o.in.gpa);
    o.in.gpa.free(o.nominal);
    o.ctor_ids.deinit(o.in.gpa);
    o.ctor_type.deinit(o.in.gpa);
    o.ctor_key.deinit(o.in.gpa);
    o.recursive_types.deinit(o.in.gpa);
    o.concat_memo.deinit(o.in.gpa);
    o.tracked_memo.deinit(o.in.gpa);
    o.names_memo.deinit(o.in.gpa);
    for (&o.walk_arenas) |*a| if (a.*) |*x| x.deinit();
    o.in.gpa.free(o.slots);
    o.in.gpa.free(o.groups);
    o.in.gpa.free(o.report_for);
    o.in.gpa.free(o.decoded);
    o.in.gpa.free(o.block_state);
    o.module_by_name.deinit(o.in.gpa);
}

/// The report for `targets`, in their order.
pub fn run(o: *Ownership, targets: []const u32) Allocator.Error![]const ModuleReport {
    try o.seedPaths();
    const arena = o.out.allocator();
    o.report_for = try o.in.gpa.alloc(bool, o.in.birs.len);
    @memset(o.report_for, false);
    for (targets) |m| if (m < o.report_for.len) {
        o.report_for[m] = true;
    };
    const reports = try arena.alloc(ModuleReport, targets.len);
    defer if (o.in.profile) |p| p.record(0, .ownership_blocks, Profile.Event.no_file, 0, o.block_ns);
    for (targets, reports) |m, *r| {
        r.* = .{ .module = m, .checked = false, .demands = &.{} };
        if (!o.isChecked(m)) continue;
        r.checked = true;
        const token = if (o.in.profile) |p| p.begin() else null;
        defer if (o.in.profile) |p| p.end(0, token.?, .ownership_module, @backingInt(o.in.graph.moduleFile(@fromBackingInt(m))), 0);
        const bir = o.in.birs[m];
        // Every summary first (§16.9): a report walk reads them all.
        for (bir.decls, 0..) |_, di| _ = try o.ensureSummary(m, @intCast(di));
        var demands: std.ArrayList(Demand) = .empty;
        const slots = try o.slotsOf(m);
        for (bir.decls, 0..) |d, di| {
            if (d.kind != .value) continue;
            const body = d.body.unwrap() orelse continue;
            if (slots[di].lines) |ls| {
                try demands.appendSlice(arena, ls);
                continue;
            }
            var scratch: std.heap.ArenaAllocator = .init(o.in.gpa);
            defer scratch.deinit();
            o.walking = m;
            defer o.walking = none;
            var w = o.walker(m, @intCast(di), scratch.allocator(), .report);
            try w.walkDecl(body);
            try w.resolve(&demands);
        }
        // Source order: by position, which is a function of the text.
        std.mem.sort(Demand, demands.items, {}, struct {
            fn less(_: void, x: Demand, y: Demand) bool {
                if (x.position.line != y.position.line) return x.position.line < y.position.line;
                if (x.position.col != y.position.col) return x.position.col < y.position.col;
                if (!std.mem.eql(u8, x.op, y.op)) return std.mem.lessThan(u8, x.op, y.op);
                return std.mem.lessThan(u8, x.base, y.base);
            }
        }.less);
        r.demands = try dedupe(demands.items);
        var lines: std.ArrayList(SummaryLine) = .empty;
        for (bir.decls, 0..) |d, di| {
            // A `crossing foreign type` (§24.2), on the trusted surface.
            if (d.kind == .foreign_type) for (bir.ownSlots(d)) |s| if (s[0] == Bir.own_type) {
                try lines.append(arena, .{ .text = try std.fmt.allocPrint(arena, "crossing {s} (words)", .{o.in.interner.slice(bir.symbol(d.name))}) });
            };
            if (d.params == 0) continue;
            if (d.kind != .value and d.kind != .foreign_value) continue;
            const s = (try o.ensureSummary(m, @intCast(di))) orelse continue;
            try lines.append(arena, .{ .text = try o.summaryText(m, @intCast(di), s) });
        }
        r.summaries = try lines.toOwnedSlice(arena);
    }
    return reports;
}

/// Two lines the walk produced twice — a demand reached through two
/// classes — are one line.
fn dedupe(items: []Demand) Allocator.Error![]const Demand {
    var n: usize = 0;
    for (items) |d| {
        if (n > 0) {
            const p = items[n - 1];
            if (p.position.line == d.position.line and p.position.col == d.position.col and
                std.mem.eql(u8, p.op, d.op) and std.mem.eql(u8, p.base, d.base) and
                std.meta.eql(p.verdict, d.verdict) and std.mem.eql(u8, p.detail, d.detail)) continue;
        }
        items[n] = d;
        n += 1;
    }
    return items[0..n];
}

fn isChecked(o: *const Ownership, m: u32) bool {
    if (m >= o.in.modules.len) return false;
    const km = &o.in.modules[m];
    const bir = o.in.birs[m];
    return km.inst_type.len == bir.insts.len and km.local_type.len == bir.locals.len;
}

fn walker(o: *Ownership, m: u32, di: u32, a: Allocator, mode: Mode) Walker {
    const km = &o.in.modules[m];
    const bir = o.in.birs[m];
    const d = bir.decls[di];
    return .{
        .o = o,
        .m = m,
        .bir = bir,
        .decl = d,
        .decl_index = di,
        .store = &km.store,
        .inst_type = km.inst_type,
        .local_type = km.local_type[d.locals_start..d.locals_end],
        .a = a,
        .mode = mode,
    };
}

// ---------------------------------------------------------------------------
// Computing summaries (§16.6, §16.9)
// ---------------------------------------------------------------------------

/// The summary of declaration `d` of module `m`, computing its group first
/// when it has none yet; while its group is being solved, the group's
/// current assumption. Null for a declaration with no summary: not a
/// function, in a module the run did not check, or a `foreign` with no
/// asserted row.
fn ensureSummary(o: *Ownership, m: u32, d: u32) Allocator.Error!?*const Summary {
    // A module the run did not check is read from its block (§28.4).
    if (!o.isChecked(m)) return o.blockSummary(m, d);
    const s = (try o.ensureWalked(m, d)) orelse return null;
    // Another module reads this one through its block (§28.3).
    if (o.in.seal and o.walking != none and o.walking != m) try o.sealSlot(m, d, &o.slots[m].?[d]);
    return s;
}

fn ensureWalked(o: *Ownership, m: u32, d: u32) Allocator.Error!?*const Summary {
    const bir = o.in.birs[m];
    if (d >= bir.decls.len) return null;
    const decl = bir.decls[d];
    // A top-level value with no parameters has one too: the cells its
    // definition makes, which are what is shared (thesis §3.10).
    if (decl.params == 0 and (decl.kind != .value or decl.body == .none)) return null;
    if (decl.kind != .value and decl.kind != .foreign_value) return null;
    const slots = try o.slotsOf(m);
    const slot = &slots[d];
    switch (slot.state) {
        .done, .computing => return &slot.sum,
        .none => {},
    }
    if (try o.assertedRow(m, d)) |row| {
        slot.sum = row;
        slot.state = .done;
        return &slot.sum;
    }
    // A `foreign` has its words' summary, or the thesis's row (§24.5).
    if (decl.kind == .foreign_value) {
        slot.sum = (try o.wordsRow(m, d)).?;
        slot.state = .done;
        return &slot.sum;
    }
    if (decl.kind != .value or decl.body == .none) return null;
    try o.computeGroup(m, d);
    return &slot.sum;
}

/// Whether `d`'s group is being solved: a call of it is a recursive call.
fn isComputing(o: *const Ownership, m: u32, d: u32) bool {
    if (m >= o.slots.len) return false;
    const slots = o.slots[m] orelse return false;
    return d < slots.len and slots[d].state == .computing;
}

fn slotsOf(o: *Ownership, m: u32) Allocator.Error![]Slot {
    if (o.slots.len == 0) {
        o.slots = try o.in.gpa.alloc(?[]Slot, o.in.birs.len);
        @memset(o.slots, null);
        o.groups = try o.in.gpa.alloc(?Groups, o.in.birs.len);
        @memset(o.groups, null);
    }
    if (o.slots[m]) |s| return s;
    const s = try o.keep.allocator().alloc(Slot, o.in.birs[m].decls.len);
    @memset(s, .{});
    o.slots[m] = s;
    return s;
}

// ---------------------------------------------------------------------------
// Summary blocks (§28.3, §28.4)
// ---------------------------------------------------------------------------

fn blockStates(o: *Ownership) Allocator.Error!void {
    if (o.block_state.len != 0) return;
    o.block_state = try o.in.gpa.alloc(u8, o.in.birs.len);
    @memset(o.block_state, 0);
    o.decoded = try o.in.gpa.alloc(?summary_bytes.Block, o.in.birs.len);
    @memset(o.decoded, null);
}

/// Module `m`'s block, read: the run's own for a module it sealed, else the
/// one the caller handed in for a module it did not check. Null when there
/// is none or it does not read — the module's functions are then callees
/// with no summary (§6.1), as they were before blocks existed.
fn blockOf(o: *Ownership, m: u32) Allocator.Error!?*const summary_bytes.Block {
    try o.blockStates();
    if (o.decoded[m]) |*b| return b;
    if (o.block_state[m] == 1) return null;
    const bytes = (if (m < o.in.blocks.len) o.in.blocks[m] else null) orelse {
        o.block_state[m] = 1;
        return null;
    };
    try o.seedPaths();
    const token = if (o.in.profile) |p| p.begin() else null;
    defer if (o.in.profile) |p| {
        o.block_ns += p.since(token.?);
    };
    o.decoded[m] = summary_bytes.read(o, o.keep.allocator(), bytes, m) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => {
            o.block_state[m] = 1;
            return null;
        },
    };
    return &o.decoded[m].?;
}

fn blockSummary(o: *Ownership, m: u32, d: u32) Allocator.Error!?*const Summary {
    const b = (try o.blockOf(m)) orelse return null;
    if (d >= b.sums.len) return null;
    if (b.sums[d]) |*s| return s;
    return null;
}

/// §28.3: the summary of declaration `d` of the checked module `m`, written
/// as a block and read back in place of the one its walk gave — what a run
/// that installed `m` reads. Under runtime safety the two must agree. Done
/// per declaration, as another module first asks for it, so that a report
/// summarises no more of the library than it did.
fn sealSlot(o: *Ownership, m: u32, d: u32, slot: *Slot) Allocator.Error!void {
    if (slot.sealed or slot.state != .done) return;
    slot.sealed = true;
    try o.seedPaths();
    const bytes = try summary_bytes.write(o, o.in.gpa, &.{.{ .decl = d, .sum = &slot.sum }});
    defer o.in.gpa.free(bytes);
    const block = summary_bytes.read(o, o.keep.allocator(), bytes, m) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => std.debug.panic("ownership: {s}'s summary block does not read back", .{try o.declName(m, d)}),
    };
    const s = block.sums[d].?;
    if (std.debug.runtime_safety and !try o.summaryDeepEql(slot.sum, s))
        std.debug.panic("ownership: {s}'s summary changes through its block", .{try o.declName(m, d)});
    slot.sum = s;
}

fn declName(o: *Ownership, m: u32, d: u32) Allocator.Error![]const u8 {
    const bir = o.in.birs[m];
    return std.fmt.allocPrint(o.keep.allocator(), "{s}.{s}", .{ o.in.module_names[m], o.in.interner.slice(bir.symbol(bir.decls[d].name)) });
}

/// Module `m`'s block (§28.4): every summary it has, computed now if it is
/// not yet, and whether each value with no parameters may hold a list. The
/// caller owns the bytes.
pub fn writeBlock(o: *Ownership, m: u32) Allocator.Error![]u8 {
    try o.seedPaths();
    const bir = o.in.birs[m];
    const saved = o.walking;
    o.walking = m;
    defer o.walking = saved;
    var rows: std.ArrayList(summary_bytes.Row) = .empty;
    defer rows.deinit(o.in.gpa);
    for (bir.decls, 0..) |decl, di| {
        const d: u32 = @intCast(di);
        const s = try o.ensureSummary(m, d);
        const holds = decl.kind == .value and decl.params == 0 and decl.body != .none and try o.valueHoldsList(m, d);
        try rows.append(o.in.gpa, .{ .decl = d, .sum = s, .holds_list = holds });
    }
    return summary_bytes.write(o, o.in.gpa, rows.items);
}

/// Whether the top-level value `d` of module `m` may hold a list (§23.6),
/// from its solved type when the run checked `m`, else from its block.
fn valueHoldsList(o: *Ownership, m: u32, d: u32) Allocator.Error!bool {
    if (!o.isChecked(m)) {
        const b = (try o.blockOf(m)) orelse return true;
        return d >= b.holds_list.len or b.holds_list[d];
    }
    const km = &o.in.modules[m];
    const body = o.in.birs[m].decls[d].body.unwrap() orelse return true;
    if (body.int() >= km.inst_type.len) return true;
    const v = km.inst_type[body.int()].unwrap() orelse return true;
    return o.holdsList(&km.store, v, 0);
}

/// The module of `(package, name)`, for a block's module table.
pub fn moduleNamed(o: *Ownership, package: SourceStore.Package, name: []const u8) ?u32 {
    if (o.module_by_name.count() == 0) {
        const keep = o.keep.allocator();
        for (o.in.module_names, 0..) |n, i| {
            if (i >= o.in.packages.len) break;
            const key = std.fmt.allocPrint(keep, "{c}{s}", .{ @as(u8, @backingInt(o.in.packages[i])), n }) catch return null;
            o.module_by_name.put(o.in.gpa, key, @intCast(i)) catch return null;
        }
    }
    var buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{c}{s}", .{ @as(u8, @backingInt(package)), name }) catch return null;
    return o.module_by_name.get(key);
}

/// Whether module `m` has a constructor at index `i`.
pub fn hasCtor(o: *const Ownership, m: u32, i: u32) bool {
    return m < o.in.birs.len and i < o.in.birs[m].ctors.len;
}

/// A constructor id's module and index in that module's table.
pub fn ctorKey(o: *const Ownership, c: u32) struct { module: u32, index: u32 } {
    const key = o.ctor_key.items[c];
    return .{ .module = @intCast(key >> 32), .index = @truncate(key) };
}

/// A summary read from a block, in this run's normal form: sorted by this
/// run's ids (§28.4).
pub fn normalizeRead(o: *Ownership, s: Summary) Allocator.Error!Summary {
    return o.normalizeRaw(s);
}

/// Whether two summaries say the same, field by field and entry by entry,
/// each first put in this run's normal form — the check that a block loses
/// nothing (§28.3).
fn summaryDeepEql(o: *Ownership, x_in: Summary, y_in: Summary) Allocator.Error!bool {
    const x = try o.normalizeRaw(x_in);
    const y = try o.normalizeRaw(y_in);
    if (x.params != y.params or x.limit != y.limit or x.asserted != y.asserted or x.coarse != y.coarse or
        x.once != y.once or x.words != y.words) return false;
    if (x.uses.len != y.uses.len or x.res.len != y.res.len or x.supply.len != y.supply.len or
        x.funs.len != y.funs.len or x.xreq.len != y.xreq.len or x.slots.len != y.slots.len or
        x.klasses.len != y.klasses.len) return false;
    for (x.uses, y.uses) |a, b| if (!std.meta.eql(a, b)) return false;
    for (x.res, y.res) |a, b| if (!resEql(a, b)) return false;
    for (x.supply, y.supply) |a, b| {
        if (a.fun != b.fun or a.k != b.k or a.path != b.path or !a.prov.eql(b.prov) or a.owned != b.owned or
            a.approx != b.approx or !a.xc.eql(b.xc)) return false;
    }
    for (x.funs, y.funs) |a, b| if (!std.meta.eql(a, b)) return false;
    for (x.xreq, y.xreq) |a, b| if (!a.eql(b)) return false;
    for (x.slots, y.slots) |a, b| if (a[0] != b[0] or a[1] != b[1]) return false;
    for (x.klasses, y.klasses) |a, b| {
        if (!try o.summaryDeepEql(a.sum.*, b.sum.*)) return false;
        if (a.binds.len != b.binds.len or a.cb_js.len != b.cb_js.len) return false;
        for (a.binds, b.binds) |p, q| {
            if (p.local != q.local or p.path != q.path or p.provs.len != q.provs.len) return false;
            for (p.provs, q.provs) |u, v| if (!resEql(u, v)) return false;
        }
        for (a.cb_js, b.cb_js) |p, q| if (p != q) return false;
    }
    return true;
}

fn resEql(a: ResEntry, b: ResEntry) bool {
    return a.path == b.path and a.prov.eql(b.prov) and a.approx == b.approx and a.xc.eql(b.xc) and a.sc.eql(b.sc);
}

/// The module's top-level declarations as strongly connected groups by
/// their references to each other, dependencies first (§16.6).
fn groupsOf(o: *Ownership, m: u32) Allocator.Error!Groups {
    _ = try o.slotsOf(m);
    if (o.groups[m]) |g| return g;
    const keep = o.keep.allocator();
    const bir = o.in.birs[m];
    const n = bir.decls.len;
    var edges: std.ArrayList(u32) = .empty;
    const starts = try keep.alloc(u32, n + 1);
    const self_edge = try keep.alloc(bool, n);
    @memset(self_edge, false);
    const tags = bir.insts.items(.tag);
    const datas = bir.insts.items(.data);
    for (bir.decls, 0..) |d, di| {
        starts[di] = @intCast(edges.items.len);
        if (d.kind != .value) continue;
        var i = d.inst_start.int();
        while (i < d.inst_end.int()) : (i += 1) {
            const target: u32 = switch (tags[i]) {
                .top => datas[i].lhs,
                .method_call => blk: {
                    if (m >= o.in.dispatch.len) break :blk none;
                    const dt = &o.in.dispatch[m];
                    const site = dt.siteOf(@fromBackingInt(i)) orelse break :blk none;
                    const ci = site.callee.unwrap() orelse break :blk none;
                    break :blk switch (dt.term(ci)) {
                        .top => |t| t.decl.int(),
                        else => none,
                    };
                },
                else => none,
            };
            if (target == none or target >= n) continue;
            if (target == di) self_edge[di] = true;
            try edges.append(keep, target);
        }
    }
    starts[n] = @intCast(edges.items.len);
    const g = try Scc.sccGroups(keep, n, edges.items, starts);
    const count = g.starts.len - 1;
    const of = try keep.alloc(u32, n);
    const recursive = try keep.alloc(bool, count);
    for (0..count) |gi| {
        const members = g.order[g.starts[gi]..g.starts[gi + 1]];
        recursive[gi] = members.len > 1 or self_edge[members[0]];
        for (members) |x| of[x] = @intCast(gi);
    }
    const out: Groups = .{ .of = of, .order = g.order, .starts = g.starts, .recursive = recursive };
    o.groups[m] = out;
    return out;
}

fn computeGroup(o: *Ownership, m: u32, d: u32) Allocator.Error!void {
    const groups = try o.groupsOf(m);
    const gi = groups.of[d];
    const all = groups.order[groups.starts[gi]..groups.starts[gi + 1]];
    const bir = o.in.birs[m];
    const slots = o.slots[m].?;
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(o.in.gpa);
    for (all) |x| {
        const dx = bir.decls[x];
        if (dx.kind != .value or dx.body == .none) continue;
        if (slots[x].state != .none) continue;
        if (try o.assertedRow(m, x)) |row| {
            slots[x] = .{ .state = .done, .sum = row };
            continue;
        }
        // A beni declaration with words has their summary (§24.5); a report
        // walks its body for its lines alone (`run`).
        if (try o.wordsRow(m, x)) |row| {
            slots[x] = .{ .state = .done, .sum = row };
            continue;
        }
        try members.append(o.in.gpa, x);
    }
    std.mem.sort(u32, members.items, {}, std.sort.asc(u32));
    for (members.items) |x| slots[x] = .{ .state = .computing, .sum = .{ .params = bir.decls[x].params } };
    if (!groups.recursive[gi]) {
        for (members.items) |x| {
            // §18.11: a declaration whose parameters and result all cross
            // has the empty summary whatever its body does; a module the run
            // does not report on need not walk it.
            const report = m < o.report_for.len and o.report_for[m];
            slots[x].sum = if (!report and try o.crosses(m, x)) .{ .params = bir.decls[x].params } else try o.walkSummary(m, x, false);
            if (o.isDictFocus(m, x)) slots[x].sum = try o.assertDictFocus(slots[x].sum);
            if (o.hostedRow(m, x)) |row| slots[x].sum = try o.assertHosted(slots[x].sum, row);
            slots[x].state = .done;
        }
        return;
    }
    // A recursive group whose members all cross is empty too (§18.11).
    if (!(m < o.report_for.len and o.report_for[m])) {
        var all_cross = true;
        for (members.items) |x| if (!try o.crosses(m, x)) {
            all_cross = false;
            break;
        };
        if (all_cross) {
            for (members.items) |x| slots[x] = .{ .state = .done, .sum = .{ .params = bir.decls[x].params } };
            return;
        }
    }
    // Optimistic, joined (§16.6): each round walks every member against
    // the current assumptions and joins what it reads off into them.
    var round: u32 = 0;
    while (round < round_cap) : (round += 1) {
        var changed = false;
        for (members.items) |x| {
            const next = try o.walkSummary(m, x, true);
            const joined = try o.join(slots[x].sum, next);
            if (!summaryEql(joined, slots[x].sum)) changed = true;
            slots[x].sum = joined;
        }
        if (!changed) break;
    }
    if (round == round_cap) {
        for (members.items) |x| {
            slots[x].sum = try o.pessimistic(slots[x].sum, .rounds);
            slots[x].lines = null;
        }
    }
    for (members.items) |x| slots[x].state = .done;
}

/// Whether every parameter of the function `d` and its result cross
/// (§4.4): no cell goes in or comes out, so its summary is empty.
fn crosses(o: *Ownership, m: u32, d: u32) Allocator.Error!bool {
    const bir = o.in.birs[m];
    const decl = bir.decls[d];
    if (decl.params == 0) return false;
    const km = &o.in.modules[m];
    const local_type = km.local_type[decl.locals_start..decl.locals_end];
    for (bir.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Inst.Index)) |p| {
        const l = switch (bir.instTag(p)) {
            .pat_var => bir.instData(p).lhs,
            else => return false,
        };
        if (l >= local_type.len) return false;
        const v = local_type[l].unwrap() orelse return false;
        if (try o.tracked(&km.store, v, 0)) return false;
    }
    const body = decl.body.unwrap() orelse return false;
    const v = km.inst_type[body.int()].unwrap() orelse return false;
    return !try o.tracked(&km.store, v, 0);
}

/// One walk of `d` and the summary read off it.
fn walkSummary(o: *Ownership, m: u32, d: u32, recursive: bool) Allocator.Error!Summary {
    // One arena per depth of nested walks (a call computes its callee's
    // summary mid-walk), kept across walks (§18.11).
    const depth = o.walk_depth;
    o.walk_depth += 1;
    defer o.walk_depth -= 1;
    const saved_walking = o.walking;
    o.walking = m;
    defer o.walking = saved_walking;
    var own: std.heap.ArenaAllocator = .init(o.in.gpa);
    defer own.deinit();
    const scratch = if (depth < o.walk_arenas.len) blk: {
        if (o.walk_arenas[depth] == null) o.walk_arenas[depth] = .init(o.in.gpa);
        break :blk &o.walk_arenas[depth].?;
    } else &own;
    defer _ = scratch.reset(.retain_capacity);
    const report = m < o.report_for.len and o.report_for[m];
    var w = o.walker(m, d, scratch.allocator(), if (report) .report else .summary);
    w.recursive = recursive;
    try w.walkDecl(w.decl.body.unwrap().?);
    var lines: std.ArrayList(Demand) = .empty;
    try w.resolve(&lines);
    if (report) o.slots[m].?[d].lines = try lines.toOwnedSlice(o.out.allocator());
    return w.readOff();
}

// ---------------------------------------------------------------------------
// The lattice (§16.2)
// ---------------------------------------------------------------------------

fn summaryEql(x: Summary, y: Summary) bool {
    if (x.limit != y.limit or x.params != y.params or x.coarse != y.coarse or x.once != y.once) return false;
    if (x.uses.len != y.uses.len or x.res.len != y.res.len or x.supply.len != y.supply.len or x.funs.len != y.funs.len) return false;
    for (x.uses, y.uses) |a, b| if (!std.meta.eql(a, b)) return false;
    for (x.res, y.res) |a, b| if (!resEql(a, b)) return false;
    for (x.supply, y.supply) |a, b| if (a.fun != b.fun or a.k != b.k or a.path != b.path or !a.prov.eql(b.prov) or a.owned != b.owned or a.approx != b.approx or !a.xc.eql(b.xc)) return false;
    for (x.funs, y.funs) |a, b| if (!std.meta.eql(a, b)) return false;
    if (x.xreq.len != y.xreq.len) return false;
    for (x.xreq, y.xreq) |a, b| if (!a.eql(b)) return false;
    return true;
}

test "recursive summaries keep iterating when only container ownership changes" {
    const before: Summary = .{ .params = 0, .res = &.{.{ .path = eps, .prov = .{ .kind = .fresh, .a = 1 }, .xc = .{ .no = 1 } }} };
    const after: Summary = .{ .params = 0, .res = &.{.{ .path = eps, .prov = .{ .kind = .fresh, .a = 1 }, .xc = .{ .no = 1 }, .sc = .{ .no = 1 } }} };
    try std.testing.expect(!summaryEql(before, after));
    try std.testing.expect(!summaryEql(after, before));
    try std.testing.expect(summaryEql(after, after));
}

/// A pure summary-instantiation scenario supplementing the corpus: a fold
/// evaluated by the entry protocol receives an init cell numbered above 100000.
fn testFoldAtEntry(initial_sc: XSum) !struct { initial: u32, result: u32 } {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const graph: Graph = .{ .modules = .empty, .deps = &.{}, .order = &.{}, .diagnostics = &.{}, .name_rows = &.{}, .rows = &.{}, .cycle_members = &.{} };
    const types = Types.empty;
    const interner: InternPool.Global = .{};
    var o: Ownership = .init(.{
        .gpa = gpa,
        .graph = &graph,
        .birs = &.{},
        .provenance = &.{},
        .dispatch = &.{},
        .modules = &.{},
        .types = &types,
        .interner = &interner,
        .module_names = &.{},
        .packages = &.{},
        .spans = &.{},
        .positions = .{ .ctx = &graph, .get = struct {
            fn get(_: *const anyopaque, _: u32, _: u32) Position {
                return .{ .line = 0, .col = 0 };
            }
        }.get },
    });
    defer o.deinit();
    try o.seedPaths();
    const bir: Bir = .{ .insts = .empty, .extra = &.{}, .string_bytes = &.{}, .symbols = &.{}, .decls = &.{}, .ctors = &.{}, .locals = &.{}, .refs = &.{}, .imports = &.{}, .exposed = &.{}, .interface = &.{}, .diagnostics = &.{}, .module_doc_start = 0, .module_doc_end = 0 };
    var store: TypeStore = .init(gpa);
    defer store.deinit();
    var w: Walker = .{ .o = &o, .m = 0, .bir = &bir, .decl = std.mem.zeroes(Bir.Decl), .decl_index = 0, .store = &store, .inst_type = &.{}, .local_type = &.{}, .a = arena.allocator(), .mode = .summary };
    try w.conds.appendSlice(w.a, &.{ .{ .atoms = &.{} }, .{ .atoms = &.{} }, .{ .atoms = &.{} } });
    const acc = Prov{ .kind = .param, .a = 1 };
    const condition: XSum = .{ .atoms = &.{.{ .kind = .spine, .a = acc }} };
    // A callback either transfers its accumulator or returns a new container
    // carrying the same exclusivity obligation; no supplied cell is an allocation.
    const callback: Summary = .{
        .params = 2,
        .uses = &.{.{ .param = 1, .path = eps, .bits = bit_w }},
        .res = &.{
            .{ .path = eps, .prov = acc, .xc = .{ .no = 1 }, .sc = condition },
            .{ .path = eps, .prov = .{ .kind = .fresh, .a = 1 }, .xc = .{ .no = 1 }, .sc = condition },
        },
    };
    try w.closures.append(w.a, .{ .captures = &.{}, .class = &callback });
    const actual = try w.single(.{ .kind = .closure, .a = 0 });
    const initial_summary: Summary = .{ .params = 0, .res = &.{.{ .path = eps, .prov = .{ .kind = .fresh, .a = 1 }, .xc = .{ .no = 1 }, .sc = initial_sc }} };
    const entry_class = [_]Walker.Class{.{ .closure = 0 }};
    const initial = try w.entryResMode(@fromBackingInt(0), .{ .classes = &entry_class, .sums = &.{&initial_summary} }, &.{}, Walker.entry_init_ns, true, false);
    try std.testing.expectEqual(@as(u32, 100001), w.cells.items[initial[0].cell].b);
    const fold: Summary = .{
        .params = 3,
        .funs = &.{.{ .param = 2, .calls = .many }},
        .supply = &.{
            .{ .fun = 2, .k = 1, .path = eps, .prov = acc, .owned = true },
            .{ .fun = 2, .k = 1, .path = eps, .prov = .{ .kind = .cb, .a = 2 }, .owned = true },
        },
        .res = &.{.{ .path = eps, .prov = .{ .kind = .cb, .a = 2 } }},
    };
    const result = try w.entryResMode(@fromBackingInt(0), .{ .classes = &entry_class, .sums = &.{&fold} }, &.{ &.{}, initial, actual }, Walker.entry_view_ns, true, false);
    return .{ .initial = try w.spineCond(initial), .result = try w.spineCond(result) };
}

test "a fold inside an entry instantiation does not seed its shared init cell" {
    const actual = try testFoldAtEntry(.{ .no = 2 });
    try std.testing.expectEqualDeep(@as(@TypeOf(actual), .{ .initial = cond_shared, .result = cond_shared }), actual);
}

test "a fold inside an entry instantiation preserves its fresh init cell" {
    const actual = try testFoldAtEntry(.{});
    try std.testing.expectEqualDeep(@as(@TypeOf(actual), .{ .initial = cond_yes, .result = cond_yes }), actual);
}

/// The conjunction of two conditions (§18.2): failing exactly beats failing
/// approximately, and a holding condition rests on both atom sets.
fn xsumAnd(a: Allocator, x: XSum, y: XSum) Allocator.Error!XSum {
    if (x.no != 0 or y.no != 0) return .{ .no = @max(x.no, y.no) };
    if (y.atoms.len == 0) return x;
    if (x.atoms.len == 0) return y;
    const all = try a.alloc(XAtom, x.atoms.len + y.atoms.len);
    @memcpy(all[0..x.atoms.len], x.atoms);
    @memcpy(all[x.atoms.len..], y.atoms);
    return .{ .atoms = sortAtoms(all) };
}

pub fn sortAtoms(all: []XAtom) []const XAtom {
    std.mem.sort(XAtom, all, {}, struct {
        fn less(_: void, p: XAtom, q: XAtom) bool {
            return p.less(q);
        }
    }.less);
    var n: usize = 0;
    for (all) |t| {
        if (n > 0 and all[n - 1].eql(t)) continue;
        all[n] = t;
        n += 1;
    }
    return all[0..n];
}

fn join(o: *Ownership, x: Summary, y: Summary) Allocator.Error!Summary {
    if (x.limit != .none) return x;
    if (y.limit != .none) return o.pessimistic(x, y.limit);
    const keep = o.keep.allocator();
    var uses: std.ArrayList(UseEntry) = .empty;
    try uses.appendSlice(keep, x.uses);
    try uses.appendSlice(keep, y.uses);
    var res: std.ArrayList(ResEntry) = .empty;
    try res.appendSlice(keep, x.res);
    try res.appendSlice(keep, y.res);
    var supply: std.ArrayList(SupplyEntry) = .empty;
    try supply.appendSlice(keep, x.supply);
    try supply.appendSlice(keep, y.supply);
    var funs: std.ArrayList(FunFacts) = .empty;
    try funs.appendSlice(keep, x.funs);
    try funs.appendSlice(keep, y.funs);
    var xreq: std.ArrayList(XAtom) = .empty;
    try xreq.appendSlice(keep, x.xreq);
    try xreq.appendSlice(keep, y.xreq);
    return o.normalize(.{
        .params = @max(x.params, y.params),
        .uses = uses.items,
        .res = res.items,
        .supply = supply.items,
        .funs = funs.items,
        .xreq = xreq.items,
        .once = x.once or y.once,
    });
}

/// Sorted, merged, and capped (§16.7).
fn normalize(o: *Ownership, s: Summary) Allocator.Error!Summary {
    const out = try o.normalizeRaw(s);
    if (out.limit != .none or out.coarse or o.widthOf(out) <= width_cap) return out;
    // Too wide (§16.7): track the widest parameters whole and cut the
    // result's and the supplies' paths, each step approximate; only a
    // summary still too wide is the pessimistic one.
    const coarse = try o.coarsen(out);
    if (o.widthOf(coarse) <= width_cap) return coarse;
    return o.pessimistic(out, .width);
}

/// Sorted and merged.
fn normalizeRaw(o: *Ownership, s: Summary) Allocator.Error!Summary {
    const keep = o.keep.allocator();
    const uses = try keep.dupe(UseEntry, s.uses);
    std.mem.sort(UseEntry, uses, {}, struct {
        fn less(_: void, x: UseEntry, y: UseEntry) bool {
            if (x.param != y.param) return x.param < y.param;
            return x.path < y.path;
        }
    }.less);
    var nu: usize = 0;
    for (uses) |u| {
        if (u.bits == 0) continue;
        if (nu > 0 and uses[nu - 1].param == u.param and uses[nu - 1].path == u.path) {
            uses[nu - 1].bits |= u.bits;
            continue;
        }
        uses[nu] = u;
        nu += 1;
    }
    const res = try keep.dupe(ResEntry, s.res);
    std.mem.sort(ResEntry, res, {}, struct {
        fn less(_: void, x: ResEntry, y: ResEntry) bool {
            if (x.path != y.path) return x.path < y.path;
            return x.prov.less(y.prov);
        }
    }.less);
    var nr: usize = 0;
    for (res) |r| {
        if (nr > 0 and res[nr - 1].path == r.path and res[nr - 1].prov.eql(r.prov)) {
            res[nr - 1].approx = res[nr - 1].approx or r.approx;
            res[nr - 1].xc = try xsumAnd(keep, res[nr - 1].xc, r.xc);
            res[nr - 1].sc = try xsumAnd(keep, res[nr - 1].sc, r.sc);
            continue;
        }
        res[nr] = r;
        nr += 1;
    }
    const supply = try keep.dupe(SupplyEntry, s.supply);
    std.mem.sort(SupplyEntry, supply, {}, struct {
        fn less(_: void, x: SupplyEntry, y: SupplyEntry) bool {
            if (x.fun != y.fun) return x.fun < y.fun;
            if (x.k != y.k) return x.k < y.k;
            if (x.path != y.path) return x.path < y.path;
            return x.prov.less(y.prov);
        }
    }.less);
    var ns: usize = 0;
    for (supply) |e| {
        if (ns > 0) {
            const p = &supply[ns - 1];
            if (p.fun == e.fun and p.k == e.k and p.path == e.path and p.prov.eql(e.prov)) {
                // A borrowed supply is exact when either side's reason is.
                const exact = (!p.owned and !p.approx) or (!e.owned and !e.approx);
                p.owned = p.owned and e.owned;
                p.approx = !p.owned and !exact;
                p.xc = try xsumAnd(keep, p.xc, e.xc);
                continue;
            }
        }
        supply[ns] = e;
        ns += 1;
    }
    const funs = try keep.dupe(FunFacts, s.funs);
    std.mem.sort(FunFacts, funs, {}, struct {
        fn less(_: void, x: FunFacts, y: FunFacts) bool {
            return x.param < y.param;
        }
    }.less);
    var nf: usize = 0;
    for (funs) |f| {
        if (nf > 0 and funs[nf - 1].param == f.param) {
            const p = &funs[nf - 1];
            p.calls = @fromBackingInt(@max(@backingInt(p.calls), @backingInt(f.calls)));
            p.need = p.need or f.need;
            p.seen = p.seen and f.seen;
            if (p.send == none) p.send = f.send;
            continue;
        }
        funs[nf] = f;
        nf += 1;
    }
    const out: Summary = .{
        .params = s.params,
        .uses = uses[0..nu],
        .res = res[0..nr],
        .supply = supply[0..ns],
        .funs = funs[0..nf],
        .limit = s.limit,
        .asserted = s.asserted,
        .coarse = s.coarse,
        .xreq = o.pruneAtoms(try keep.dupe(XAtom, s.xreq)),
        .once = s.once,
        .words = s.words,
        .slots = s.slots,
        .klasses = s.klasses,
    };
    return out;
}

/// The number of distinct paths in a summary's widest component.
fn widthOf(o: *const Ownership, s: Summary) usize {
    _ = o;
    var res_paths: usize = 0;
    for (s.res, 0..) |r, i| {
        if (i == 0 or s.res[i - 1].path != r.path) res_paths += 1;
    }
    var supply_paths: usize = 0;
    for (s.supply, 0..) |e, i| {
        if (i == 0) {
            supply_paths += 1;
            continue;
        }
        const p = s.supply[i - 1];
        if (p.fun != e.fun or p.k != e.k or p.path != e.path) supply_paths += 1;
    }
    return @max(s.uses.len, @max(res_paths, supply_paths));
}

/// `p` cut to its first `d` steps, then `⋆`.
fn truncate(o: *Ownership, p: u32, d: usize) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    const s = o.steps(p, &buf);
    if (s.len <= d) return p;
    var at: u32 = eps;
    for (s[0..d]) |st| at = try o.child(at, st.kind, st.arg);
    return o.child(at, .any, 0);
}

fn coarsen(o: *Ownership, s: Summary) Allocator.Error!Summary {
    const keep = o.keep.allocator();
    // Parameters tracked whole, the widest first, until the uses fit.
    var uses: std.ArrayList(UseEntry) = .empty;
    try uses.appendSlice(keep, s.uses);
    while (uses.items.len > width_cap) {
        var widest: u32 = 0;
        var most: usize = 0;
        var p: u32 = 0;
        while (p < s.params) : (p += 1) {
            var n: usize = 0;
            for (uses.items) |u| if (u.param == p) {
                n += 1;
            };
            if (n > most) {
                most = n;
                widest = p;
            }
        }
        if (most <= 1) break;
        var bits: u8 = 0;
        var kept: std.ArrayList(UseEntry) = .empty;
        for (uses.items) |u| {
            if (u.param == widest) bits |= u.bits else try kept.append(keep, u);
        }
        try kept.append(keep, .{ .param = widest, .path = eps, .bits = bits & ~bit_x });
        uses = kept;
    }
    // The result's and the supplies' paths, cut shallower until they fit.
    const res = try keep.dupe(ResEntry, s.res);
    const supply = try keep.dupe(SupplyEntry, s.supply);
    var depth: usize = k_limit;
    while (depth > 0) {
        const trial = try o.normalizeRaw(.{ .params = s.params, .uses = uses.items, .res = res, .supply = supply, .funs = s.funs, .xreq = s.xreq });
        if (o.widthOf(trial) <= width_cap) break;
        depth -= 1;
        for (res) |*r| {
            const t = try o.truncate(r.path, depth);
            if (t != r.path) {
                r.path = t;
                r.approx = true;
            }
        }
        for (supply) |*e| {
            const t = try o.truncate(e.path, depth);
            if (t != e.path) {
                e.path = t;
                e.approx = true;
            }
        }
    }
    var out = try o.normalizeRaw(.{ .params = s.params, .uses = uses.items, .res = res, .supply = supply, .funs = s.funs, .asserted = s.asserted, .xreq = s.xreq, .once = s.once });
    out.coarse = true;
    return out;
}

/// The pessimistic summary of §16.2: every parameter written, kept and
/// returned whole, the result unknown, every callback out of sight.
fn pessimistic(o: *Ownership, s: Summary, why: Limit) Allocator.Error!Summary {
    const keep = o.keep.allocator();
    const uses = try keep.alloc(UseEntry, s.params);
    for (uses, 0..) |*u, i| u.* = .{ .param = @intCast(i), .path = eps, .bits = bit_r | bit_a | bit_e | bit_w };
    const res = try keep.dupe(ResEntry, &.{.{ .path = eps, .prov = .{ .kind = .top, .a = 0 }, .approx = true, .xc = .{ .no = 1 } }});
    const funs = try keep.alloc(FunFacts, s.funs.len);
    for (funs, s.funs) |*f, g| f.* = .{ .param = g.param, .calls = .many, .need = true, .seen = false };
    return .{ .params = s.params, .uses = uses, .res = res, .funs = funs, .limit = why, .asserted = s.asserted, .once = s.once };
}

// ---------------------------------------------------------------------------
// The asserted rows (§16.8)
// ---------------------------------------------------------------------------

fn assertedRow(o: *Ownership, m: u32, d: u32) Allocator.Error!?Summary {
    if (o.in.packages[m] != .core or !std.mem.eql(u8, o.in.module_names[m], "List")) return null;
    const bir = o.in.birs[m];
    const name = o.in.interner.slice(bir.symbol(bir.decls[d].name));
    const R = bit_r;
    const A = bit_a;
    const W = bit_w | bit_x;
    const elem = try o.child(eps, .elem, 0);
    const p = struct {
        fn at(i: u32, path: u32) Prov {
            return .{ .kind = .param, .a = i, .path = path };
        }
    }.at;
    const fresh: Prov = .{ .kind = .fresh, .a = 1 };
    const keep = o.keep.allocator();
    const lost: XSum = .{ .no = 1 };
    var uses: []const UseEntry = &.{};
    var res: []const ResEntry = &.{};
    var supply: []const SupplyEntry = &.{};
    var funs: []const FunFacts = &.{};
    if (eqlAny(name, &.{ "set", "insertAt", "put" })) {
        // A writer whose base is π₁ and which stores π₃ (§18.3: the base
        // stays exclusive when π₃ is and shares nothing with its elements).
        uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 2, .path = eps, .bits = A } };
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = p(0, eps), .xc = try o.stores(0, 2, elem) }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(2, eps) } });
    } else if (std.mem.eql(u8, name, "push")) {
        uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 1, .path = eps, .bits = A } };
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = p(0, eps), .xc = try o.stores(0, 1, elem) }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(1, eps) } });
    } else if (eqlAny(name, &.{ "pop", "removeAt", "swap", "done" })) {
        // A writer that stores nothing new: it drops an element, or permutes
        // two (`swap`, §22.5), so the list stays exclusive when it was
        // (thesis §3.11's row: `excl if π₁ excl`).
        uses = &.{.{ .param = 0, .path = eps, .bits = R | A | W }};
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) } });
    } else if (std.mem.eql(u8, name, "cons")) {
        // §3.1 as amended for slice 3f: a prepend copies, so it reads its
        // base and writes nothing. Its result is a new array, or — the
        // runtime's re-cons — a header over the base's own array, so it
        // aliases π₂ as well (thesis §3.8: "a prepend into a view returns a
        // new header over the same array").
        uses = &.{ .{ .param = 0, .path = eps, .bits = A }, .{ .param = 1, .path = eps, .bits = R | A }, .{ .param = 1, .path = elem, .bits = A } };
        const made = try keep.alloc(XAtom, 3);
        made[0] = .{ .kind = .excl, .a = p(0, eps) };
        made[1] = .{ .kind = .excl, .a = p(1, eps) };
        made[2] = sepAtom(p(0, eps), p(1, elem));
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = fresh, .xc = .{ .atoms = sortAtoms(made) } }, .{ .path = eps, .prov = p(1, eps) }, .{ .path = elem, .prov = p(1, elem) }, .{ .path = elem, .prov = p(0, eps) } });
    } else if (std.mem.eql(u8, name, "append")) {
        // Copying in the elements of a list that lives on (thesis §3.8).
        uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 1, .path = eps, .bits = R }, .{ .param = 1, .path = elem, .bits = A } };
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = p(0, eps), .xc = lost }, .{ .path = elem, .prov = p(0, elem) }, .{ .path = elem, .prov = p(1, elem) } });
    } else if (eqlAny(name, &.{ "copy", "sliceOf" })) {
        uses = &.{ .{ .param = 0, .path = eps, .bits = R }, .{ .param = 0, .path = elem, .bits = A } };
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = fresh, .xc = lost }, .{ .path = elem, .prov = p(0, elem) } });
    } else if (eqlAny(name, &.{ "length", "offset" })) {
        uses = &.{.{ .param = 0, .path = eps, .bits = R }};
    } else if (eqlAny(name, &.{ "at", "unsafeGet" })) {
        uses = &.{ .{ .param = 0, .path = eps, .bits = R }, .{ .param = 0, .path = elem, .bits = A } };
        res = try keep.dupe(ResEntry, &.{.{ .path = eps, .prov = p(0, elem) }});
    } else if (std.mem.eql(u8, name, "traverseAt")) {
        // §18.5, the traversal primitive: the element, taken out.
        uses = &.{ .{ .param = 0, .path = eps, .bits = R }, .{ .param = 0, .path = elem, .bits = A } };
        res = try keep.dupe(ResEntry, &.{.{ .path = eps, .prov = .{ .kind = .param, .a = 0, .path = elem, .taken = true } }});
    } else if (std.mem.eql(u8, name, "focus")) {
        // §18.5, the focus primitive: the element taken out, handed to the
        // callback owned when the list is exclusive, and its result put
        // back; the list stays exclusive when the callback keeps shape.
        uses = &.{ .{ .param = 0, .path = eps, .bits = R | A | W }, .{ .param = 0, .path = elem, .bits = A } };
        const kept_shape = try keep.dupe(XAtom, &.{.{ .kind = .keep, .a = .{ .kind = .cb, .a = 2 }, .b = p(0, eps) }});
        res = try keep.dupe(ResEntry, &.{
            .{ .path = eps, .prov = p(0, eps), .xc = .{ .atoms = kept_shape } },
            .{ .path = elem, .prov = p(0, elem) },
            .{ .path = elem, .prov = .{ .kind = .cb, .a = 2 } },
        });
        const whole = try keep.dupe(XAtom, &.{.{ .kind = .excl, .a = p(0, eps) }});
        supply = try keep.dupe(SupplyEntry, &.{.{ .fun = 2, .k = 0, .path = eps, .prov = .{ .kind = .param, .a = 0, .path = elem, .taken = true }, .owned = true, .xc = .{ .atoms = whole } }});
        funs = try keep.dupe(FunFacts, &.{.{ .param = 2, .calls = .once }});
    } else if (std.mem.eql(u8, name, "view")) {
        // A view is its base's array: it is exclusive when the base is.
        uses = &.{.{ .param = 0, .path = eps, .bits = R | A }};
        const whole = try keep.dupe(XAtom, &.{.{ .kind = .excl, .a = p(0, eps) }});
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = eps, .prov = fresh, .xc = .{ .atoms = whole } }, .{ .path = elem, .prov = p(0, elem) } });
    } else if (std.mem.eql(u8, name, "base")) {
        uses = &.{.{ .param = 0, .path = eps, .bits = R | A }};
        res = try keep.dupe(ResEntry, &.{ .{ .path = eps, .prov = p(0, eps) }, .{ .path = elem, .prov = p(0, elem) } });
    } else if (std.mem.eql(u8, name, "builder")) {
        res = try keep.dupe(ResEntry, &.{.{ .path = eps, .prov = fresh }});
    } else return null;
    return try o.normalize(.{
        .params = o.in.birs[m].decls[d].params,
        .uses = try keep.dupe(UseEntry, uses),
        .res = res,
        .supply = supply,
        .funs = funs,
        .asserted = true,
    });
}

// ---------------------------------------------------------------------------
// Ownership words (§24)
// ---------------------------------------------------------------------------

/// The summary a declaration's ownership words give (§24.2), or the
/// thesis's row for a `foreign` that carries none (§24.5). Null for a beni
/// declaration with no words: its summary is read off its body.
fn wordsRow(o: *Ownership, m: u32, d: u32) Allocator.Error!?Summary {
    const bir = o.in.birs[m];
    const decl = bir.decls[d];
    const slots = try o.flipped(m, d, bir.ownSlots(decl));
    if (slots.len == 0 and decl.kind != .foreign_value) return null;
    const n = decl.params;
    const keep = o.keep.allocator();
    const W = @import("../parse/Ast.zig").OwnWord;
    // The annotation's parameter types: which are functions written out,
    // and how many parameters each such function takes.
    var fn_arity = try keep.alloc(?u32, n);
    @memset(fn_arity, null);
    if (decl.annotation.unwrap()) |ann| if (bir.instTag(ann) == .type_fn) {
        const ps = bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(ann).lhs))), Inst.Index);
        for (ps, 0..) |p, i| {
            if (i >= n or bir.instTag(p) != .type_fn) continue;
            fn_arity[i] = @intCast(bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(bir.instData(p).lhs))), Inst.Index).len);
        }
    };
    var uses: std.ArrayList(UseEntry) = .empty;
    var res: std.ArrayList(ResEntry) = .empty;
    var supply: std.ArrayList(SupplyEntry) = .empty;
    var funs: std.ArrayList(FunFacts) = .empty;
    const any = try o.child(eps, .any, 0);
    var returned = false;
    var result_words: u32 = 0;
    for (slots) |s| if (s[0] == Bir.own_result) {
        result_words = s[1];
    };
    for (0..n) |iu| {
        const i: u32 = @intCast(iu);
        var words: u32 = 0;
        for (slots) |s| if (s[0] == i) {
            words = s[1];
        };
        const has = struct {
            fn f(x: u32, w: W) bool {
                return x & w.bit() != 0;
            }
        }.f;
        // What is not written is the worst case (§24.2).
        if (words == 0) words = W.escaped.bit();
        if (fn_arity[i]) |arity| {
            // A function parameter: how often it is called, what it is
            // handed, and whether JavaScript keeps it.
            const kept = has(words, .escaped);
            const calls: Calls = if (has(words, .unused)) .zero else if (has(words, .once)) .once else .many;
            try funs.append(keep, .{ .param = i, .calls = calls, .seen = !kept });
            if (calls != .zero) {
                for (0..arity) |k| try supply.append(keep, if (has(words, .owned))
                    .{ .fun = i, .k = @intCast(k), .path = eps, .prov = .{ .kind = .fresh }, .owned = true }
                else
                    .{ .fun = i, .k = @intCast(k), .path = eps, .prov = .{ .kind = .top, .a = 0 }, .owned = false });
            }
            // A function kept by JavaScript escapes what it captured (§18.6).
            if (kept) try uses.append(keep, .{ .param = i, .path = eps, .bits = bit_r | bit_j }) else if (calls != .zero) try uses.append(keep, .{ .param = i, .path = eps, .bits = bit_r });
            if (has(words, .returned)) {
                returned = true;
                try res.append(keep, .{ .path = eps, .prov = .{ .kind = .cb, .a = i } });
            }
            if (has(words, .aliased)) try res.append(keep, .{ .path = any, .prov = .{ .kind = .cb, .a = i }, .approx = true });
            continue;
        }
        var bits: u8 = 0;
        if (!has(words, .unused)) bits |= bit_r;
        if (has(words, .aliased) or has(words, .returned)) bits |= bit_a;
        if (has(words, .escaped)) bits |= bit_e;
        if (has(words, .consumed)) bits |= bit_w | bit_x | bit_d;
        if (bits != 0) try uses.append(keep, .{ .param = i, .path = eps, .bits = bits });
        const p: Prov = .{ .kind = .param, .a = i, .path = eps };
        if (has(words, .returned)) {
            returned = true;
            try res.append(keep, .{ .path = eps, .prov = p });
        }
        if (has(words, .aliased)) try res.append(keep, .{ .path = any, .prov = p, .approx = true });
    }
    const lost: XSum = .{ .no = 1 };
    if (result_words & W.fresh.bit() != 0) {
        try res.append(keep, .{ .path = eps, .prov = .{ .kind = .fresh, .a = 1 }, .xc = if (result_words & W.exclusive.bit() != 0) .{} else lost });
    } else if (result_words & W.escaped.bit() != 0) {
        try res.append(keep, .{ .path = eps, .prov = .{ .kind = .esc, .a = 1 }, .xc = lost });
    } else if (result_words & W.unknown.bit() != 0 or !returned) {
        try res.append(keep, .{ .path = eps, .prov = .{ .kind = .top, .a = 0 }, .xc = lost });
    }
    var out = try o.normalize(.{
        .params = n,
        .uses = uses.items,
        .res = res.items,
        .supply = supply.items,
        .funs = funs.items,
        .asserted = true,
    });
    out.words = slots.len != 0;
    // The thesis's row for a `foreign` without words is a default, not an
    // assertion anyone made (§24.5).
    out.asserted = out.words;
    return out;
}

/// The words of declaration `d` of module `m`, with `--ownership-flips`'s
/// edits applied when it names the declaration (§24.6).
fn flipped(o: *Ownership, m: u32, d: u32, slots: []const [2]u32) Allocator.Error![]const [2]u32 {
    const flip = o.in.flip orelse return slots;
    const bir = o.in.birs[m];
    if (!std.mem.eql(u8, o.in.module_names[m], flip.module)) return slots;
    if (!std.mem.eql(u8, o.in.interner.slice(bir.symbol(bir.decls[d].name)), flip.decl)) return slots;
    var out: std.ArrayList([2]u32) = .empty;
    try out.appendSlice(o.keep.allocator(), slots);
    var met = true;
    for (flip.edits) |e| {
        const i = for (out.items, 0..) |s, i| {
            if (s[0] == e.slot) break i;
        } else blk: {
            try out.append(o.keep.allocator(), .{ e.slot, 0 });
            break :blk out.items.len - 1;
        };
        if (e.from) |w| {
            if (out.items[i][1] & w.bit() == 0) met = false;
            out.items[i][1] &= ~w.bit();
        }
        if (e.to) |w| out.items[i][1] |= w.bit();
    }
    o.flip_applied = met;
    return out.items;
}

/// core/Dict's `focus` (§20.8), whose row is its body's with one fact asserted.
fn isDictFocus(o: *const Ownership, m: u32, d: u32) bool {
    if (o.in.packages[m] != .core or !std.mem.eql(u8, o.in.module_names[m], "Dict")) return false;
    const bir = o.in.birs[m];
    return std.mem.eql(u8, o.in.interner.slice(bir.symbol(bir.decls[d].name)), "focus");
}

/// The dictionary's destructive read (§20.8, thesis §7 *A dictionary*): the
/// value handed to `alter` is taken out of the tree and owned, on condition
/// that the dictionary is exclusive — as `List.focus`'s supply is (§18.5).
fn assertDictFocus(o: *Ownership, s: Summary) Allocator.Error!Summary {
    if (s.limit != .none) return s;
    const keep = o.keep.allocator();
    const whole = try keep.dupe(XAtom, &.{.{ .kind = .excl, .a = .{ .kind = .param, .a = 0, .path = eps } }});
    const supply = try keep.dupe(SupplyEntry, s.supply);
    for (supply) |*e| {
        if (e.fun != 2 or e.prov.kind != .param or e.prov.a != 0) continue;
        e.owned = true;
        e.approx = false;
        e.prov.taken = true;
        e.xc = .{ .atoms = whole };
    }
    // What `alter` returns is put back where the value was taken from: the
    // dictionary stays exclusive when it keeps shape (thesis §7: "excl if π₁
    // excl and g keeps shape"), which states the body's `sep` of the value
    // put back from the rest in the focus's own terms.
    const keep_atom: XAtom = .{ .kind = .keep, .a = .{ .kind = .cb, .a = 2 }, .b = .{ .kind = .param, .a = 0, .path = eps } };
    const res = try keep.dupe(ResEntry, s.res);
    for (res) |*r| {
        var atoms: std.ArrayList(XAtom) = .empty;
        var dropped = false;
        for (r.xc.atoms) |x| {
            if (x.a.kind == .cb or x.b.kind == .cb) {
                dropped = true;
                continue;
            }
            try atoms.append(keep, x);
        }
        if (!dropped) continue;
        if (r.prov.kind == .param) try atoms.append(keep, keep_atom);
        r.xc = .{ .no = r.xc.no, .atoms = sortAtoms(atoms.items) };
    }
    for (res) |*r| {
        if (r.prov.kind != .param or r.prov.a != 0) continue;
        for (supply) |e| {
            if (e.fun != 2 or e.prov.kind != .param or !e.prov.taken or !o.isPrefix(e.prov.path, r.prov.path)) continue;
            const tail = (try o.suffix(e.prov.path, r.prov.path)) orelse continue;
            const selected = try o.concat(e.path, tail);
            r.sc = .{ .atoms = try keep.dupe(XAtom, &.{
                .{ .kind = .spine, .a = r.prov },
                .{ .kind = .keep_spine, .a = .{ .kind = .cb, .a = 2, .path = selected }, .b = r.prov },
            }) };
            break;
        }
    }
    var out = s;
    out.supply = supply;
    out.res = res;
    out.asserted = true;
    return o.normalize(out);
}

/// §23.3: the send positions — `browser`'s `Hosted` functions that hand a
/// body to the runtime, which calls it with a send, and the taggers the
/// runtime sends the results of.
const HostedRow = enum {
    /// `job`, `later`: π₁ is handed a send as its parameter 1.
    body,
    /// `tap`, `hook`: π₁ is handed a send of a raw value, and π₂ tags each
    /// value it sends, supplied borrowed — one value goes through the tagger
    /// of every current subscription of its key.
    sub,
    /// `mapJob`, `mapLater`: π₂ tags what the inner send gave up, owned.
    map_owned,
    /// `mapTap`: π₂ tags what a subscription's tagger made of a value that
    /// went to every tagger of its key: borrowed.
    map_borrowed,
    /// `runJob`, `callJob`: π₂ is a send the runtime forwards to a body whose
    /// sends were checked where it was made (`job`'s row).
    forward,
};

fn hostedRow(o: *const Ownership, m: u32, d: u32) ?HostedRow {
    if (m >= o.in.platform_names.len or !std.mem.eql(u8, o.in.platform_names[m], "browser")) return null;
    if (!std.mem.eql(u8, o.in.module_names[m], "Hosted")) return null;
    const bir = o.in.birs[m];
    const name = o.in.interner.slice(bir.symbol(bir.decls[d].name));
    if (eqlAny(name, &.{ "job", "later" })) return .body;
    if (eqlAny(name, &.{ "tap", "hook" })) return .sub;
    if (eqlAny(name, &.{ "mapJob", "mapLater" })) return .map_owned;
    if (std.mem.eql(u8, name, "mapTap")) return .map_borrowed;
    if (eqlAny(name, &.{ "runJob", "callJob" })) return .forward;
    return null;
}

/// The row of a send position (§23.3): the body's inferred summary — what
/// the value it makes holds — with the facts of the runtime it hands its
/// functions to asserted, which no beni body shows: the runtime calls them,
/// many times, a body with a send and a tagger with what is sent.
fn assertHosted(o: *Ownership, s: Summary, row: HostedRow) Allocator.Error!Summary {
    if (s.limit != .none) return s;
    const keep = o.keep.allocator();
    // π₁'s and π₂'s facts are the row's. In the `map…` and `forward`
    // rows π₁ is a `Job`, `Later` or `Tap` — a `foreign
    // type`, no function, with no facts to keep — checked where it was made.
    var funs: std.ArrayList(FunFacts) = .empty;
    var supply: std.ArrayList(SupplyEntry) = .empty;
    for (s.funs) |f| if (f.param > 1) try funs.append(keep, f);
    for (s.supply) |e| if (e.fun > 1) try supply.append(keep, e);
    const fresh: Prov = .{ .kind = .fresh };
    switch (row) {
        .body => try funs.append(keep, .{ .param = 0, .calls = .many, .send = 0 }),
        .sub => {
            try funs.append(keep, .{ .param = 0, .calls = .many, .send = 0 });
            try funs.append(keep, .{ .param = 1, .calls = .many, .need = true });
            try supply.append(keep, .{ .fun = 1, .k = 0, .path = eps, .prov = fresh, .owned = false });
        },
        .map_owned, .map_borrowed => {
            try funs.append(keep, .{ .param = 1, .calls = .many, .need = true });
            try supply.append(keep, .{ .fun = 1, .k = 0, .path = eps, .prov = fresh, .owned = row == .map_owned });
        },
        // The job calls it; what it is handed was checked at the job's send
        // position, so the row supplies it nothing.
        .forward => try funs.append(keep, .{ .param = 1, .calls = .many }),
    }
    var out = s;
    out.funs = funs.items;
    out.supply = supply.items;
    out.asserted = true;
    return o.normalize(out);
}

/// §18.3: a writer that stores parameter `v` in its base `b` keeps the base
/// exclusive when `v` is, and shares no cell with the base's elements.
fn stores(o: *Ownership, b: u32, v: u32, elem: u32) Allocator.Error!XSum {
    const atoms = try o.keep.allocator().alloc(XAtom, 2);
    atoms[0] = .{ .kind = .excl, .a = .{ .kind = .param, .a = v, .path = eps } };
    atoms[1] = sepAtom(.{ .kind = .param, .a = v, .path = eps }, .{ .kind = .param, .a = b, .path = elem });
    return .{ .atoms = sortAtoms(atoms) };
}

/// Sorted, without an `excl` that another implies: a value's deep
/// exclusivity covers every path under it.
fn pruneAtoms(o: *const Ownership, all: []XAtom) []const XAtom {
    const sorted = sortAtoms(all);
    var n: usize = 0;
    var out = all[0..sorted.len];
    for (sorted, 0..) |t, i| {
        if (t.kind == .excl) {
            var implied = false;
            for (sorted, 0..) |u, j| {
                if (j == i or u.kind != .excl or u.a.kind != t.a.kind or u.a.a != t.a.a or u.a.path == t.a.path) continue;
                if (o.isPrefix(u.a.path, t.a.path)) implied = true;
            }
            if (implied) continue;
        }
        out[n] = t;
        n += 1;
    }
    return out[0..n];
}

/// `sep a b` with its two sides in order, so that one fact is one atom.
pub fn sepAtom(a: Prov, b: Prov) XAtom {
    return if (b.less(a)) .{ .kind = .sep, .a = b, .b = a } else .{ .kind = .sep, .a = a, .b = b };
}

fn eqlAny(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Printing a summary (§16.11)
// ---------------------------------------------------------------------------

fn summaryText(o: *Ownership, m: u32, d: u32, s: *const Summary) Allocator.Error![]const u8 {
    const arena = o.out.allocator();
    const bir = o.in.birs[m];
    o.text_sum = s;
    defer o.text_sum = null;
    var parts: std.ArrayList([]const u8) = .empty;
    // Parameters' bits, in text order.
    var uses: std.ArrayList([]const u8) = .empty;
    for (s.uses) |u| {
        var buf: std.Io.Writer.Allocating = .init(arena);
        const wr = &buf.writer;
        wr.print("π{d}", .{u.param + 1}) catch return error.OutOfMemory;
        o.writePath(wr, u.path) catch return error.OutOfMemory;
        wr.writeByte(' ') catch return error.OutOfMemory;
        inline for (.{ .{ bit_r, "R" }, .{ bit_a, "A" }, .{ bit_e, "E" }, .{ bit_j, "J" } }) |b| {
            if (u.bits & b[0] != 0) wr.writeAll(b[1]) catch return error.OutOfMemory;
        }
        // `w`: written only through an approximate step.
        // `S`: a send's write, of every cell below the path too (§23.2).
        if (u.bits & bit_w != 0) wr.writeAll(if (u.bits & bit_d != 0)
            (if (u.bits & bit_x != 0) "S" else "s")
        else if (u.bits & bit_x != 0) "W" else "w") catch return error.OutOfMemory;
        try uses.append(arena, try buf.toOwnedSlice());
    }
    sortText(uses.items);
    if (uses.items.len > 0) try parts.append(arena, try std.mem.join(arena, ", ", uses.items));
    // The result, grouped by path in text order.
    var groups: std.ArrayList(struct { path: []const u8, provs: std.ArrayList([]const u8) }) = .empty;
    for (s.res) |r| {
        const pt = try o.pathText(r.path);
        var found: ?usize = null;
        for (groups.items, 0..) |g, i| if (std.mem.eql(u8, g.path, pt)) {
            found = i;
        };
        const i = found orelse blk: {
            try groups.append(arena, .{ .path = pt, .provs = .empty });
            break :blk groups.items.len - 1;
        };
        const t = try std.fmt.allocPrint(arena, "{s}{s}", .{ try o.provText(r.prov), try o.xsumText(r.xc) });
        try groups.items[i].provs.append(arena, if (r.approx) try std.fmt.allocPrint(arena, "~{s}", .{t}) else t);
    }
    if (groups.items.len > 0) {
        var gtexts: std.ArrayList([]const u8) = .empty;
        for (groups.items) |*g| {
            sortText(g.provs.items);
            const provs = try std.mem.join(arena, " ", g.provs.items);
            try gtexts.append(arena, if (g.path.len == 0) provs else try std.fmt.allocPrint(arena, "{s} {s}", .{ g.path, provs }));
        }
        sortText(gtexts.items);
        try parts.append(arena, try std.fmt.allocPrint(arena, "res {s}", .{try std.mem.join(arena, ", ", gtexts.items)}));
    }
    // Function parameters.
    for (s.funs) |f| {
        var buf: std.Io.Writer.Allocating = .init(arena);
        const wr = &buf.writer;
        // A function slot (§24.9) is named by its parameter and path.
        const fname = if (f.param >= s.params and f.param - s.params < s.slots.len)
            try std.fmt.allocPrint(arena, "π{d}{s}", .{ s.slots[f.param - s.params][0] + 1, try o.pathText(s.slots[f.param - s.params][1]) })
        else
            try std.fmt.allocPrint(arena, "π{d}", .{f.param + 1});
        wr.print("{s} calls {s}", .{ fname, switch (f.calls) {
            .zero => "0",
            .once => "≤1",
            .many => "many",
        } }) catch return error.OutOfMemory;
        if (f.need) wr.writeAll(", need owned") catch return error.OutOfMemory;
        if (!f.seen) wr.writeAll(", unseen") catch return error.OutOfMemory;
        if (f.send != none) wr.print(", sends π{d}", .{f.send + 1}) catch return error.OutOfMemory;
        var sup: std.ArrayList([]const u8) = .empty;
        for (s.supply) |e| {
            if (e.fun != f.param) continue;
            const pt = try o.pathText(e.path);
            try sup.append(arena, try std.fmt.allocPrint(arena, "supply {d}{s} {s} {s}{s}{s}", .{ e.k + 1, pt, try o.provText(e.prov), if (e.owned) "owned" else "borrowed", if (e.prov.taken) " taken" else "", try o.xsumText(e.xc) }));
        }
        sortText(sup.items);
        for (sup.items) |t| wr.print(", {s}", .{t}) catch return error.OutOfMemory;
        try parts.append(arena, try buf.toOwnedSlice());
    }
    if (s.xreq.len > 0) {
        var reqs: std.ArrayList([]const u8) = .empty;
        for (s.xreq) |x| try reqs.append(arena, try o.atomText(x));
        sortText(reqs.items);
        try parts.append(arena, try std.fmt.allocPrint(arena, "xreq {s}", .{try std.mem.join(arena, ", ", reqs.items)}));
    }
    if (s.limit != .none) try parts.append(arena, if (s.limit == .width) "limit width" else "limit rounds");
    if (s.coarse) try parts.append(arena, "coarse");
    const facts = if (parts.items.len == 0) "unused" else try std.mem.join(arena, "; ", parts.items);
    const name = o.in.interner.slice(bir.symbol(bir.decls[d].name));
    return std.fmt.allocPrint(arena, "summary {s}: {s}{s}", .{ name, facts, if (s.words) " (words)" else if (s.asserted) " (asserted)" else "" });
}

/// A condition as a summary line prints it (§18.3): nothing when it holds
/// outright, `{excl π2, sep π1[*] π2}` when it rests on atoms, `{lost}` or
/// `{shared}` when it fails approximately or exactly.
fn xsumText(o: *Ownership, x: XSum) Allocator.Error![]const u8 {
    const arena = o.out.allocator();
    if (x.no == 1) return "{lost}";
    if (x.no == 2) return "{shared}";
    if (x.atoms.len == 0) return "";
    var parts: std.ArrayList([]const u8) = .empty;
    for (x.atoms) |t| try parts.append(arena, try o.atomText(t));
    sortText(parts.items);
    return std.fmt.allocPrint(arena, "{{{s}}}", .{try std.mem.join(arena, ", ", parts.items)});
}

fn atomText(o: *Ownership, x: XAtom) Allocator.Error![]const u8 {
    const arena = o.out.allocator();
    return switch (x.kind) {
        .excl => std.fmt.allocPrint(arena, "excl {s}", .{try o.provText(x.a)}),
        .spine => std.fmt.allocPrint(arena, "spine {s}", .{try o.provText(x.a)}),
        .sep_spine => std.fmt.allocPrint(arena, "sep-spine {s} {s}", .{ try o.provText(x.a), try o.provText(x.b) }),
        .keep_spine => std.fmt.allocPrint(arena, "keep-spine {s} {s}", .{ try o.provText(x.a), try o.provText(x.b) }),
        .sep => std.fmt.allocPrint(arena, "sep {s} {s}", .{ try o.provText(x.a), try o.provText(x.b) }),
        .keep => std.fmt.allocPrint(arena, "keep {s} {s}", .{ try o.provText(x.a), try o.provText(x.b) }),
    };
}

fn sortText(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
}

fn pathText(o: *Ownership, p: u32) Allocator.Error![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(o.out.allocator());
    o.writePath(&buf.writer, p) catch return error.OutOfMemory;
    return buf.toOwnedSlice();
}

fn provText(o: *Ownership, p: Prov) Allocator.Error![]const u8 {
    const arena = o.out.allocator();
    const pt = try o.pathText(p.path);
    return switch (p.kind) {
        .param => std.fmt.allocPrint(arena, "π{d}{s}", .{ p.a + 1, pt }),
        .fresh => if (p.a == 0) "fresh" else std.fmt.allocPrint(arena, "fresh{d}", .{p.a}),
        .esc => if (p.a == 0) "esc" else std.fmt.allocPrint(arena, "esc{d}", .{p.a}),
        .shared => blk: {
            const b = o.in.birs[p.a];
            break :blk std.fmt.allocPrint(arena, "shared({s}.{s}){s}", .{ o.in.module_names[p.a], o.in.interner.slice(b.symbol(b.decls[p.b].name)), pt });
        },
        .top => if (p.a == 1) "⊤limit" else "⊤",
        .cb => if (o.text_sum) |s| (if (p.b == 0 and p.a >= s.params and p.a - s.params < s.slots.len) blk: {
            const slot = s.slots[p.a - s.params];
            break :blk std.fmt.allocPrint(arena, "cb(π{d}{s}){s}", .{ slot[0] + 1, try o.pathText(slot[1]), pt });
        } else std.fmt.allocPrint(arena, "cb{d}{s}", .{ p.a + 1, pt })) else std.fmt.allocPrint(arena, "cb{d}{s}", .{ p.a + 1, pt }),
        .klass => "λ",
        .env => std.fmt.allocPrint(arena, "◇{d}{s}", .{ p.a, pt }),
    };
}

// ---------------------------------------------------------------------------
// Paths (§4.1)
// ---------------------------------------------------------------------------

pub const StepKind = enum(u8) { field, tuple, ctor, elem, env, any, markup_render, markup_event };

const Paths = struct {
    parent: std.ArrayList(u32) = .empty,
    kind: std.ArrayList(StepKind) = .empty,
    arg: std.ArrayList(u32) = .empty,
    depth: std.ArrayList(u8) = .empty,
    /// The path without its first step, once asked (§18.11).
    rest: std.ArrayList(u32) = .empty,
    map: std.AutoHashMapUnmanaged([3]u32, u32) = .empty,

    fn deinit(p: *Paths, gpa: Allocator) void {
        p.parent.deinit(gpa);
        p.kind.deinit(gpa);
        p.arg.deinit(gpa);
        p.depth.deinit(gpa);
        p.rest.deinit(gpa);
        p.map.deinit(gpa);
    }
};

/// ε, the empty path. Its id is 0 once `Paths` has been seeded.
pub const eps: u32 = 0;

fn seedPaths(o: *Ownership) Allocator.Error!void {
    if (o.paths.parent.items.len != 0) return;
    const gpa = o.in.gpa;
    try o.paths.parent.append(gpa, none);
    try o.paths.kind.append(gpa, .any);
    try o.paths.arg.append(gpa, 0);
    try o.paths.depth.append(gpa, 0);
    try o.paths.rest.append(gpa, none);
}

fn child(o: *Ownership, parent: u32, kind: StepKind, arg: u32) Allocator.Error!u32 {
    std.debug.assert(o.paths.parent.items.len != 0);
    // The cut: a path never grows past k steps; a `⋆` absorbs what is below it.
    if (o.paths.depth.items[parent] >= k_limit) return parent;
    if (parent != eps and o.paths.kind.items[parent] == .any) return parent;
    // A recursive type is folded (thesis §3.1): a constructor step into a
    // value of a type the path is already inside goes on from where the
    // path first entered that type, so `t#.3#.3` is `t#.3`'s twin and a
    // summary over a tree stays a few paths wide (§16.7).
    if (kind == .ctor) if (o.foldAt(parent, arg)) |at| return o.rawChild(at, kind, arg);
    return o.rawChild(parent, kind, arg);
}

fn foldAt(o: *Ownership, parent: u32, arg: u32) ?u32 {
    const ty = o.ctorType(arg / 64) orelse return null;
    var chain: [k_limit + 1]u32 = undefined;
    var n: usize = 0;
    var at = parent;
    while (at != eps and at != none) : (at = o.paths.parent.items[at]) {
        chain[n] = at;
        n += 1;
    }
    // Root first: `chain[n - 1]` is the first step.
    var i = n;
    while (i > 0) {
        i -= 1;
        const node = chain[i];
        if (o.paths.kind.items[node] != .ctor) continue;
        const t = o.ctorType(o.paths.arg.items[node] / 64) orelse continue;
        if (t == ty) return o.paths.parent.items[node];
    }
    return null;
}

/// Whether `p` names a representative place (thesis §3.1, §3.11): one that
/// stands for many run-time places — a list's elements, or a level of a
/// recursive value that folding merged with the others. A demand there, or
/// a holder there, is an approximate fact.
fn representative(o: *Ownership, p: u32) Allocator.Error!bool {
    var at = p;
    while (at != eps and at != none) : (at = o.paths.parent.items[at]) {
        switch (o.paths.kind.items[at]) {
            .elem => return true,
            .ctor => if (o.ctorType(o.paths.arg.items[at] / 64)) |t| if (try o.typeRecursive(t)) return true,
            else => {},
        }
    }
    return false;
}

/// Whether a path goes through core Dict's recursive tree (§20.8).
fn dictTreePath(o: *Ownership, p: u32) Allocator.Error!bool {
    var at = p;
    while (at != eps and at != none) : (at = o.paths.parent.items[at]) {
        if (o.paths.kind.items[at] != .ctor) continue;
        const t = o.ctorType(o.paths.arg.items[at] / 64) orelse continue;
        const m: u32 = @intCast(t >> 32);
        if (m >= o.in.packages.len or o.in.packages[m] != .core or !std.mem.eql(u8, o.in.module_names[m], "Dict")) continue;
        if (try o.typeRecursive(t)) return true;
    }
    return false;
}

/// Whether the type `(module, declaration)` reaches itself through its own
/// definition.
fn typeRecursive(o: *Ownership, key: u64) Allocator.Error!bool {
    if (o.recursive_types.get(key)) |r| return r;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(o.in.gpa);
    var work: std.ArrayList(u64) = .empty;
    defer work.deinit(o.in.gpa);
    try o.typeHeads(key, &work);
    var found = false;
    while (work.pop()) |k| {
        if (k == key) {
            found = true;
            break;
        }
        const gop = try seen.getOrPut(o.in.gpa, k);
        if (gop.found_existing) continue;
        try o.typeHeads(k, &work);
    }
    try o.recursive_types.put(o.in.gpa, key, found);
    return found;
}

/// The types a type's definition names directly.
fn typeHeads(o: *Ownership, key: u64, out: *std.ArrayList(u64)) Allocator.Error!void {
    const m: u32 = @intCast(key >> 32);
    const d: u32 = @truncate(key);
    if (m >= o.in.birs.len) return;
    const bir = o.in.birs[m];
    if (d >= bir.decls.len) return;
    const decl = bir.decls[d];
    switch (decl.kind) {
        .type => for (bir.declCtors(decl)) |c| {
            for (bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Inst.Index)) |arg| try o.typeExprHeads(m, bir, arg, out, 0);
        },
        .type_alias => if (decl.annotation.unwrap()) |body| try o.typeExprHeads(m, bir, body, out, 0),
        else => {},
    }
}

fn typeExprHeads(o: *Ownership, m: u32, bir: *const Bir, inst: Inst.Index, out: *std.ArrayList(u64), depth: u32) Allocator.Error!void {
    if (depth > type_depth) return;
    const tag = bir.instTag(inst);
    const data = bir.instData(inst);
    const graph_m: Graph.Index = @fromBackingInt(@intCast(m));
    switch (tag) {
        .type_tuple => for (bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |el| try o.typeExprHeads(m, bir, el, out, depth + 1),
        .type_record => for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |fl| try o.typeExprHeads(m, bir, fl.value, out, depth + 1),
        .type_record_ext => for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field)) |fl| try o.typeExprHeads(m, bir, fl.value, out, depth + 1),
        .type_top, .ext_type, .schema_type_top, .ext_schema_type => try o.pushHead(o.in.types.headId(graph_m, tag, data), out),
        .type_app => {
            const head: Inst.Index = @fromBackingInt(@intCast(data.lhs));
            try o.pushHead(o.in.types.headId(graph_m, bir.instTag(head), bir.instData(head)), out);
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |arg| try o.typeExprHeads(m, bir, arg, out, depth + 1);
        },
        else => {},
    }
}

fn pushHead(o: *Ownership, id: TypeId, out: *std.ArrayList(u64)) Allocator.Error!void {
    if (id == .none or id.int() >= o.in.types.entries.len) return;
    const e = o.in.types.entries[id.int()];
    try out.append(o.in.gpa, (@as(u64, e.module.int()) << 32) | e.decl.int());
}

fn ctorType(o: *const Ownership, c: u32) ?u64 {
    if (c >= o.ctor_type.items.len) return null;
    const t = o.ctor_type.items[c];
    return if (t == std.math.maxInt(u64)) null else t;
}

pub fn rawChild(o: *Ownership, parent: u32, kind: StepKind, arg: u32) Allocator.Error!u32 {
    const key: [3]u32 = .{ parent, @backingInt(kind), arg };
    const gop = try o.paths.map.getOrPut(o.in.gpa, key);
    if (gop.found_existing) return gop.value_ptr.*;
    const id: u32 = @intCast(o.paths.parent.items.len);
    gop.value_ptr.* = id;
    try o.paths.parent.append(o.in.gpa, parent);
    try o.paths.kind.append(o.in.gpa, kind);
    try o.paths.arg.append(o.in.gpa, arg);
    try o.paths.depth.append(o.in.gpa, o.paths.depth.items[parent] + 1);
    try o.paths.rest.append(o.in.gpa, none);
    return id;
}

pub const Step = struct { kind: StepKind, arg: u32 };

/// The steps of `p`, root first.
pub fn steps(o: *const Ownership, p: u32, buf: *[k_limit + 1]Step) []const Step {
    const n: usize = o.paths.depth.items[p];
    var at = p;
    var i = n;
    while (i > 0) {
        i -= 1;
        buf[i] = .{ .kind = o.paths.kind.items[at], .arg = o.paths.arg.items[at] };
        at = o.paths.parent.items[at];
    }
    return buf[0..n];
}

/// `s` followed by `p`'s steps.
fn prepend(o: *Ownership, s: Step, p: u32) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    const rest = o.steps(p, &buf);
    var at = try o.child(eps, s.kind, s.arg);
    for (rest) |r| at = try o.child(at, r.kind, r.arg);
    return at;
}

/// `p`'s steps followed by `q`'s.
fn concat(o: *Ownership, p: u32, q: u32) Allocator.Error!u32 {
    if (q == eps) return p;
    if (p == eps) return q;
    if (o.concat_memo.get(.{ p, q })) |r| return r;
    var buf: [k_limit + 1]Step = undefined;
    var at = p;
    for (o.steps(q, &buf)) |r| at = try o.child(at, r.kind, r.arg);
    try o.concat_memo.put(o.in.gpa, .{ p, q }, at);
    return at;
}

/// Whether one path is a prefix of the other, step by step, with `⋆`
/// overlapping anything (§4.1).
fn overlap(o: *const Ownership, p: u32, q: u32) bool {
    var bp: [k_limit + 1]Step = undefined;
    var bq: [k_limit + 1]Step = undefined;
    const sp = o.steps(p, &bp);
    const sq = o.steps(q, &bq);
    const n = @min(sp.len, sq.len);
    for (0..n) |i| {
        if (sp[i].kind == .any or sq[i].kind == .any) return true;
        if (sp[i].kind != sq[i].kind or sp[i].arg != sq[i].arg) return false;
    }
    return true;
}

/// When `p` is a prefix of `q`, the rest of `q`; else null.
fn suffix(o: *Ownership, p: u32, q: u32) Allocator.Error!?u32 {
    var bp: [k_limit + 1]Step = undefined;
    var bq: [k_limit + 1]Step = undefined;
    const sp = o.steps(p, &bp);
    const sq = o.steps(q, &bq);
    if (sp.len > sq.len) return null;
    for (sp, sq[0..sp.len]) |x, y| if (x.kind != y.kind or x.arg != y.arg) return null;
    var at: u32 = eps;
    for (sq[sp.len..]) |s| at = try o.child(at, s.kind, s.arg);
    return at;
}

/// Whether `p` is a prefix of `q`, `⋆` matching anything.
fn isPrefix(o: *const Ownership, p: u32, q: u32) bool {
    return o.paths.depth.items[p] <= o.paths.depth.items[q] and o.overlap(p, q);
}

fn hasStep(o: *const Ownership, p: u32, kind: StepKind) bool {
    var at = p;
    while (at != eps and at != none) : (at = o.paths.parent.items[at]) {
        if (o.paths.kind.items[at] == kind) return true;
    }
    return false;
}

fn firstStep(o: *const Ownership, p: u32) ?Step {
    if (p == eps) return null;
    var at = p;
    while (o.paths.parent.items[at] != eps) at = o.paths.parent.items[at];
    return .{ .kind = o.paths.kind.items[at], .arg = o.paths.arg.items[at] };
}

/// `p` without its first step.
fn dropFirst(o: *Ownership, p: u32) Allocator.Error!u32 {
    if (o.paths.rest.items[p] != none) return o.paths.rest.items[p];
    const r = try o.dropFirstRaw(p);
    o.paths.rest.items[p] = r;
    return r;
}

fn dropFirstRaw(o: *Ownership, p: u32) Allocator.Error!u32 {
    var buf: [k_limit + 1]Step = undefined;
    const s = o.steps(p, &buf);
    var at: u32 = eps;
    for (s[1..]) |r| at = try o.child(at, r.kind, r.arg);
    return at;
}

fn writePath(o: *const Ownership, w: *std.Io.Writer, p: u32) std.Io.Writer.Error!void {
    var buf: [k_limit + 1]Step = undefined;
    for (o.steps(p, &buf)) |s| switch (s.kind) {
        .field => try w.print(".{s}", .{o.in.interner.slice(@fromBackingInt(@intCast(s.arg)))}),
        .tuple => try w.print(".{d}", .{s.arg}),
        .ctor => {
            // `#Name.i`: the constructor and the argument.
            const c = s.arg / 64;
            const name: []const u8 = blk: {
                if (c >= o.ctor_key.items.len) break :blk "";
                const key = o.ctor_key.items[c];
                const m: u32 = @intCast(key >> 32);
                const i: u32 = @truncate(key);
                if (m >= o.in.birs.len or i == none) break :blk "";
                const bir = o.in.birs[m];
                if (i >= bir.ctors.len) break :blk "";
                break :blk o.in.interner.slice(bir.symbol(bir.ctors[i].name));
            };
            try w.print("#{s}.{d}", .{ name, s.arg % 64 });
        },
        .elem => try w.writeAll("[*]"),
        .env => try w.writeAll("◇"),
        .markup_render => try w.writeAll("⟨render⟩"),
        .markup_event => try w.writeAll("⟨events⟩"),
        .any => try w.writeAll("⋆"),
    };
}

pub fn ctorId(o: *Ownership, module: u32, index: u32) Allocator.Error!u32 {
    const key = (@as(u64, module) << 32) | index;
    const gop = try o.ctor_ids.getOrPut(o.in.gpa, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(o.ctor_ids.count() - 1);
        // The type that declares it, for folding (§16.7).
        var ty: u64 = std.math.maxInt(u64);
        if (module < o.in.birs.len and index != none) {
            const bir = o.in.birs[module];
            if (index < bir.ctors.len) ty = (@as(u64, module) << 32) | bir.ctors[index].decl.int();
        }
        try o.ctor_type.append(o.in.gpa, ty);
        try o.ctor_key.append(o.in.gpa, key);
    }
    return gop.value_ptr.*;
}

// ---------------------------------------------------------------------------
// Crossing and sharing over types (§4.4, §6.1)
// ---------------------------------------------------------------------------

const NominalFacts = struct {
    /// A `List`, a function or a non-primitive `foreign type` is reachable
    /// in the body without going through a type parameter.
    own: bool = false,
    /// A type parameter is reachable in the body.
    params: bool = false,
    /// One constructor of one field: the release representation may make a
    /// value of it its field (thesis §3.1, A10).
    unboxed: bool = false,
    /// §23.4: a `List` is reachable in the body without going through a
    /// type parameter, a function or a `foreign type` other than `List`.
    list: bool = false,
};

fn isPrimitive(o: *const Ownership, id: TypeId) bool {
    const wk = o.in.types.well_known;
    return id == wk.int or id == wk.float or id == wk.char or id == wk.string;
}

fn nominalFacts(o: *Ownership, id: TypeId) Allocator.Error!NominalFacts {
    if (id == .none or id.int() >= o.in.types.entries.len) return .{ .own = true };
    if (o.nominal.len == 0) {
        o.nominal = try o.in.gpa.alloc(?NominalFacts, o.in.types.entries.len);
        @memset(o.nominal, null);
    }
    if (o.nominal[id.int()]) |f| return f;
    // Optimistic while in progress: a type's own recursion adds nothing
    // its other edges do not (the least fixpoint of "holds a cell").
    o.nominal[id.int()] = .{};
    const e = o.in.types.entries[id.int()];
    var facts: NominalFacts = .{};
    if (e.schema_endpoint) {
        facts.own = true;
        facts.list = true;
    } else switch (e.kind) {
        .foreign => {
            facts.own = id == o.in.types.well_known.list or !o.isPrimitive(id);
            facts.list = id == o.in.types.well_known.list;
            // `crossing foreign type` (§24.2): it holds no cell.
            if (e.module.int() < o.in.birs.len) {
                const bir = o.in.birs[e.module.int()];
                for (bir.ownSlots(bir.decl(e.decl))) |s| if (s[0] == Bir.own_type) {
                    facts.own = false;
                };
            }
        },
        .alias, .adt => {
            const m = e.module.int();
            const bir = o.in.birs[m];
            const d = bir.decl(e.decl);
            if (e.kind == .alias) {
                if (d.annotation.unwrap()) |body| facts = try o.birTypeFacts(m, bir, body, 0);
            } else {
                const ctors = bir.declCtors(d);
                for (ctors) |c| {
                    const args = bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Inst.Index);
                    for (args) |arg| {
                        const f = try o.birTypeFacts(m, bir, arg, 0);
                        facts.own = facts.own or f.own;
                        facts.params = facts.params or f.params;
                        facts.list = facts.list or f.list;
                    }
                }
                if (ctors.len == 1) {
                    facts.unboxed = bir.extraSlice(.{ .start = ctors[0].args_start, .end = ctors[0].args_end }, Inst.Index).len == 1;
                }
            }
        },
    }
    o.nominal[id.int()] = facts;
    return facts;
}

fn birTypeFacts(o: *Ownership, m: u32, bir: *const Bir, inst: Inst.Index, depth: u32) Allocator.Error!NominalFacts {
    if (depth > type_depth) return .{ .own = true, .list = true };
    const tag = bir.instTag(inst);
    const data = bir.instData(inst);
    const graph_m: Graph.Index = @fromBackingInt(@intCast(m));
    switch (tag) {
        .type_fn => return .{ .own = true },
        .type_var => return .{ .params = true },
        .type_unit => return .{},
        .type_tuple => {
            var f: NominalFacts = .{};
            for (bir.extraSlice(Bir.inlineRange(data), Inst.Index)) |el| f = joinFacts(f, try o.birTypeFacts(m, bir, el, depth + 1));
            return f;
        },
        .type_record => {
            var f: NominalFacts = .{};
            for (bir.extraSlice(Bir.inlineRange(data), Bir.Field)) |fl| f = joinFacts(f, try o.birTypeFacts(m, bir, fl.value, depth + 1));
            return f;
        },
        .type_record_ext => {
            var f: NominalFacts = .{ .params = true };
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field)) |fl| f = joinFacts(f, try o.birTypeFacts(m, bir, fl.value, depth + 1));
            return f;
        },
        .type_top, .ext_type, .schema_type_top, .ext_schema_type => {
            const nf = try o.nominalFacts(o.in.types.headId(graph_m, tag, data));
            return .{ .own = nf.own, .list = nf.list };
        },
        .type_app => {
            const head: Inst.Index = @fromBackingInt(@intCast(data.lhs));
            const nf = try o.nominalFacts(o.in.types.headId(graph_m, bir.instTag(head), bir.instData(head)));
            var f: NominalFacts = .{ .own = nf.own, .list = nf.list };
            if (nf.params) for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |arg| {
                f = joinFacts(f, try o.birTypeFacts(m, bir, arg, depth + 1));
            };
            return f;
        },
        else => return .{ .own = true, .list = true },
    }
}

fn joinFacts(a: NominalFacts, b: NominalFacts) NominalFacts {
    return .{ .own = a.own or b.own, .params = a.params or b.params, .list = a.list or b.list };
}

/// §23.4: whether a value of this type may hold a list that beni code can
/// reach without `Js`: what a send gives up that `update` could write in
/// place. A function's captures and a `foreign type`'s insides are not
/// such a list — §16.5's `pending` follows a writing closure, and a value
/// read out of JavaScript is `⊤` wherever it is read.
fn holdsList(o: *Ownership, store: *TypeStore, v: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    switch (store.resolvedContent(v)) {
        // A type variable may be anything; an alias `resolvedContent` left
        // unexpanded is taken to hold one rather than walked.
        .flex, .rigid, .err, .alias => return true,
        .structure => |s| switch (s) {
            .unit, .empty_record, .func => return false,
            .tuple => |r| {
                for (store.vars(r)) |el| if (try o.holdsList(store, el, depth + 1)) return true;
                return false;
            },
            .record => |r| {
                for (store.fields(r.fields)) |f| if (try o.holdsList(store, f.value, depth + 1)) return true;
                return o.holdsList(store, r.ext, depth + 1);
            },
            .app => |a| {
                if (a.type == o.in.types.well_known.list) return true;
                const nf = try o.nominalFacts(a.type);
                if (nf.list) return true;
                if (nf.params) for (store.vars(a.args)) |arg| if (try o.holdsList(store, arg, depth + 1)) return true;
                return false;
            },
        },
    }
}

/// Whether a value of this type may hold a cell (§4.4: it does not cross).
fn tracked(o: *Ownership, store: *TypeStore, v: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    switch (store.resolvedContent(v)) {
        .flex, .rigid, .err => return true,
        .alias => return true,
        .structure => |s| switch (s) {
            .unit, .empty_record => return false,
            .func => return true,
            .tuple => |r| {
                for (store.vars(r)) |el| if (try o.tracked(store, el, depth + 1)) return true;
                return false;
            },
            .record => |r| {
                for (store.fields(r.fields)) |f| if (try o.tracked(store, f.value, depth + 1)) return true;
                return o.tracked(store, r.ext, depth + 1);
            },
            .app => |a| {
                if (a.type == o.in.types.well_known.list) return true;
                const nf = try o.nominalFacts(a.type);
                if (nf.own) return true;
                if (nf.params) for (store.vars(a.args)) |arg| if (try o.tracked(store, arg, depth + 1)) return true;
                return false;
            },
        },
    }
}

/// §23.6: the view-event rule's reason (P6).
const view_event_detail = "a message a view event builds may hold it — a list of the model, or one a handler keeps from one dispatch to the next — and the check does not tell update's arms apart (§20.5, §23.6, P6)";

/// §23.2: what a send does with what it is handed — every cell of it is
/// given up to `update`, which may write it in place.
const send_class: Summary = .{ .params = 1, .uses = &.{.{ .param = 0, .path = eps, .bits = bit_w | bit_x | bit_d }}, .asserted = true };

/// The `k`th parameter type of a function type, when `v` is one.
fn funcParam(store: *TypeStore, v: Var, k: u32) ?Var {
    switch (store.resolvedContent(v)) {
        .structure => |st| switch (st) {
            .func => |fun| {
                const ps = store.vars(fun.params);
                return if (k < ps.len) ps[k] else null;
            },
            else => return null,
        },
        else => return null,
    }
}

fn isFunc(store: *TypeStore, v: Var) bool {
    return switch (store.resolvedContent(v)) {
        .structure => |s| s == .func,
        else => false,
    };
}

fn unboxed(o: *Ownership, id: TypeId) Allocator.Error!bool {
    return (try o.nominalFacts(id)).unboxed;
}

/// Whether the type variable `v` occurs inside `t`, below its root: a value
/// of type `v` can then be neither a `t` nor hold one, since no value is
/// cyclic (§6.1) — an element of a `List a` is never the list.
fn occursBelow(store: *TypeStore, v: Var, t: Var, depth: u32) bool {
    if (depth > type_depth) return false;
    const root, const c = store.resolved(t);
    if (depth > 0 and root == v) return true;
    return switch (c) {
        .structure => |s| switch (s) {
            .unit, .empty_record => false,
            .func => |f| blk: {
                for (store.vars(f.params)) |p| if (occursBelow(store, v, p, depth + 1)) break :blk true;
                break :blk occursBelow(store, v, f.result, depth + 1);
            },
            .tuple => |r| blk: {
                for (store.vars(r)) |el| if (occursBelow(store, v, el, depth + 1)) break :blk true;
                break :blk false;
            },
            .record => |r| blk: {
                for (store.fields(r.fields)) |f| if (occursBelow(store, v, f.value, depth + 1)) break :blk true;
                break :blk occursBelow(store, v, r.ext, depth + 1);
            },
            .app => |a| blk: {
                for (store.vars(a.args)) |arg| if (occursBelow(store, v, arg, depth + 1)) break :blk true;
                break :blk false;
            },
        },
        else => false,
    };
}

fn isVar(store: *TypeStore, v: Var) ?Var {
    const root, const c = store.resolved(v);
    return switch (c) {
        .flex, .rigid => root,
        else => null,
    };
}

/// `core/List`'s `Builder`, which `done` hands over as the list it is: the
/// two types are one run-time object (§16.8's `done` row).
fn builderId(o: *Ownership) TypeId {
    if (o.builder_id) |id| return id;
    var found: TypeId = .none;
    for (o.in.types.entries, 0..) |e, i| {
        if (e.package != .core or e.kind != .foreign) continue;
        if (!std.mem.eql(u8, o.in.interner.slice(e.module_name), "List")) continue;
        if (!std.mem.eql(u8, o.in.interner.slice(e.name), "Builder")) continue;
        found = @fromBackingInt(@intCast(i));
        break;
    }
    o.builder_id = found;
    return found;
}

const ResultErr = struct { ty: TypeId, ctor: u32 };

/// §26.2: core `Result`'s type id and the id of its `Err` constructor,
/// the payload a `?` returns from its definition.
fn resultErr(o: *Ownership) Allocator.Error!ResultErr {
    if (o.result_err) |r| return r;
    var ty: TypeId = .none;
    for (o.in.types.entries, 0..) |e, i| {
        if (e.package != .core) continue;
        if (!std.mem.eql(u8, o.in.interner.slice(e.module_name), "Result")) continue;
        if (!std.mem.eql(u8, o.in.interner.slice(e.name), "Result")) continue;
        ty = @fromBackingInt(@intCast(i));
        break;
    }
    var ctor: u32 = none;
    if (ty != .none) for (o.in.module_names, 0..) |name, m| {
        if (m >= o.in.packages.len or o.in.packages[m] != .core or !std.mem.eql(u8, name, "Result")) continue;
        const bir = o.in.birs[m];
        for (bir.ctors, 0..) |c, i| {
            if (!std.mem.eql(u8, o.in.interner.slice(bir.symbol(c.name)), "Err")) continue;
            ctor = try o.ctorId(@intCast(m), @intCast(i));
            break;
        }
        break;
    };
    if (ctor == none) ty = .none;
    o.result_err = .{ .ty = ty, .ctor = ctor };
    return o.result_err.?;
}

fn sameRepresentation(o: *Ownership, x: TypeId, y: TypeId) bool {
    if (x == y) return true;
    const list = o.in.types.well_known.list;
    const builder = o.builderId();
    if (builder == .none) return false;
    return (x == list or x == builder) and (y == list or y == builder);
}

/// Whether a value of type `a` may be the same run-time object as one of
/// type `b` (§6.1).
fn mayShare(o: *Ownership, store: *TypeStore, a: Var, b: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    if (isVar(store, a)) |va| if (occursBelow(store, va, b, 0)) return false;
    if (isVar(store, b)) |vb| if (occursBelow(store, vb, a, 0)) return false;
    const ca = store.resolvedContent(a);
    const cb = store.resolvedContent(b);
    const sa = switch (ca) {
        .structure => |s| s,
        else => return true,
    };
    const sb = switch (cb) {
        .structure => |s| s,
        else => return true,
    };
    switch (sa) {
        .app => |x| {
            if (try o.unboxed(x.type)) return true;
            switch (sb) {
                .app => |y| {
                    if (try o.unboxed(y.type)) return true;
                    if (!o.sameRepresentation(x.type, y.type)) return false;
                    const xs = store.vars(x.args);
                    const ys = store.vars(y.args);
                    if (xs.len != ys.len) return true;
                    for (xs, ys) |p, q| if (!try o.mayShare(store, p, q, depth + 1)) return false;
                    return true;
                },
                else => return false,
            }
        },
        .func => return sb == .func or (sb == .app and try o.unboxed(sb.app.type)),
        // Slice 3f's rule that two closed records with different fields
        // are never one object served only `map`'s identity promise, and
        // went with it (§27.4).
        .record => return sb == .record or (sb == .app and try o.unboxed(sb.app.type)),
        .tuple => return sb == .tuple or (sb == .app and try o.unboxed(sb.app.type)),
        .unit, .empty_record => return false,
    }
}

/// Whether a value of type `r`, or a part of it, may be the same object
/// as a value of type `t` (§6.1).
fn mayHold(o: *Ownership, store: *TypeStore, r: Var, t: Var, depth: u32) Allocator.Error!bool {
    if (depth > type_depth) return true;
    if (isVar(store, r)) |vr| if (occursBelow(store, vr, t, 0)) return false;
    if (try o.mayShare(store, r, t, depth)) return true;
    switch (store.resolvedContent(r)) {
        .flex, .rigid, .err, .alias => return true,
        .structure => |s| switch (s) {
            .unit, .empty_record => return false,
            .func => return true,
            .tuple => |rg| {
                for (store.vars(rg)) |el| if (try o.mayHold(store, el, t, depth + 1)) return true;
                return false;
            },
            .record => |rc| {
                for (store.fields(rc.fields)) |f| if (try o.mayHold(store, f.value, t, depth + 1)) return true;
                return o.tracked(store, rc.ext, depth + 1);
            },
            .app => |a| {
                if (a.type == o.in.types.well_known.list) {
                    for (store.vars(a.args)) |arg| if (try o.mayHold(store, arg, t, depth + 1)) return true;
                    return false;
                }
                const nf = try o.nominalFacts(a.type);
                // A body we do not instantiate: it may hold anything it holds.
                if (nf.own) return true;
                if (nf.params) for (store.vars(a.args)) |arg| if (try o.mayHold(store, arg, t, depth + 1)) return true;
                return false;
            },
        },
    }
}

// ---------------------------------------------------------------------------
// One declaration
// ---------------------------------------------------------------------------

const Mode = enum { summary, report };

const CellKind = enum(u8) { site, param, result, env, shared, top, closure, func, cbres, taken, payload };

const Cell = struct {
    kind: CellKind,
    /// site/result: the instruction; param: the parameter pattern
    /// instruction; env: the captured local; shared: the module; closure:
    /// its index; func: the module; cbres: the function parameter's index;
    /// taken: the element cell it was taken from (§18.5); payload: the
    /// program constructor's call (§20.5).
    a: u32,
    /// shared/func: the declaration; param: 1 for a lambda's or local
    /// function's parameter, 0 for the declaration's own; result: 0 for a
    /// call with no summary (§6.1), else the callee's fresh number; cbres:
    /// the call's instruction; taken: the instruction that took it.
    b: u32 = 0,
    /// taken: the path below the element.
    path: u32 = eps,
    ty: Var.Optional = .none,
    /// shared: a cell the definition made at `path` (§16.3), whose own
    /// elements, when it has any, are cells of their own — not one cell
    /// that stands for everything below, as a value with no summary is.
    made: bool = false,
};

/// §18.2: an atom of a condition in the walk's vocabulary — cells that
/// arrived from outside. `excl`: `a` is a cell; `sep`: `a` and `b` are
/// cells, `a ≤ b`, and `sep c c` of a callback's result is "fresh across
/// calls"; `keep`: `a` the declaration's function parameter, `b` a cell.
const WAtom = struct {
    kind: @FieldType(XAtom, "kind"),
    a: u32,
    b: u32 = none,
    path: u32 = eps,

    fn less(x: WAtom, y: WAtom) bool {
        if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
        if (x.a != y.a) return x.a < y.a;
        if (x.b != y.b) return x.b < y.b;
        return x.path < y.path;
    }
};

/// §18.2: a condition, as the walk keeps it.
const WCond = struct {
    /// 0: holds, given `atoms`; 1: fails, approximately; 2: fails, exactly.
    no: u8 = 0,
    atoms: []const WAtom = &.{},
};

/// The conditions every walk starts with.
const cond_yes: u32 = 0;
const cond_lost: u32 = 1;
const cond_shared: u32 = 2;

/// What relying on a condition came to (§18.4).
const Rely = enum { ok, approx, exact };

/// An atom relied on, and the frame that relied on it (§18.4).
const Req = struct { frame: u32, atom: WAtom };

/// The earliest points a cell escaped: for a reason of its own (`gen`), and
/// by §18.6's rule only (`js`, with the call as `why`).
const EscAt = struct { gen: u32 = none, js: u32 = none, why: u32 = 0 };

const Escape = struct { cell: u32, point: u32, why: u32, ctx: u32, prev: u32 };

const Entry = struct {
    path: u32,
    cell: u32,
    /// 0 when exact; else 1 + the instruction of the call whose
    /// conservative aliasing or identity promise put the entry here (§8.4).
    approx: u32 = 0,
};

const AV = []const Entry;

/// `deep`: in a closure's `env_writes`, a send gives up every cell at or
/// below the path (§23.2).
const Capture = struct { local: u32, path: u32, deep: bool = false };

/// How a lambda was consumed: what decides its demands on its own
/// parameters (§16.5).
const Consumption = struct {
    kind: enum { supply, local, no_summary, pending },
    /// supply: per parameter of the lambda, a borrowed supply's reason, or
    /// null when every supply it writes is owned.
    bad: []const ?[]const u8 = &.{},
    /// supply: whether the reason is a limit (an element).
    bad_approx: []const bool = &.{},
    /// supply: the cause each reason is, `supply` or `exclusive` (§18.4).
    bad_cause: []const Cause = &.{},
    /// The summary or callee that decided it, for the note.
    name: []const u8 = "",
    /// pending: why.
    why: []const u8 = "",
};

const Closure = struct {
    captures: []const Capture,
    params: []const Inst.Index = &.{},
    frame: u32 = 0,
    class: ?*const Summary = null,
    /// The captured cells the lambda's body escaped (§16.4 item 4).
    env_escapes: []const Capture = &.{},
    consumed: std.ArrayList(Consumption) = .empty,
    /// §18.8: the captures its body writes; non-empty makes it once.
    env_writes: []const Capture = &.{},
    /// A local function's: its captures are read when it runs, so its
    /// creation demand is made at each call.
    local: bool = false,
    /// §18.8: the probes a once closure's creation and calls made.
    once_probes: std.ArrayList(u32) = .empty,
    /// §18.8: the probes its calls made, on its own cell.
    call_probes: std.ArrayList(u32) = .empty,
    /// §18.8: why it may run more than once, when it may.
    once_bad: ?[]const u8 = null,
    once_bad_approx: bool = false,
    /// §24.9: a lambda a callee's result carried here (`Carried`): what
    /// each of its captures held, as this body holds it, in place of locals
    /// of this body; and the function values its calls of the callee's
    /// function parameters go to.
    binds: []const SynBind = &.{},
    cb_avs: []const SynCall = &.{},
    carried: bool = false,

    const SynBind = struct { local: u32, path: u32, av: AV };
    const SynCall = struct { j: u32, av: AV };
};

const Use = struct {
    local: u32,
    path: u32,
    /// A record update's base is used at every path but these fields.
    except: []const u32 = &.{},
    point: u32,
    frame: u32,
    ctx: u32,
    token: u32,
    /// A use a closure's consumption makes of what it captured: the
    /// closure, which its once creation allows to stay live (§18.8).
    via: u32 = none,
    /// §28.6: the variable path read, as written, when the use is one.
    at: [2]u32 = .{ none, none },
};

const Holder = struct {
    local: u32,
    path: u32,
    approx: u32,
    /// Found through a split element's list (§18.4 item 4): the element itself.
    split: bool = false,
};

/// `creation`: a once closure's creation, or a local function's call, demanding
/// the captures it writes (§18.8) — resolved first, like a probe, and a write.
const DemandKind = enum { report, callsite, probe, value, creation };

const DemandRec = struct {
    kind: DemandKind = .report,
    token: u32,
    op: []const u8,
    base: []const u8,
    /// The root local of the base when it is a variable path.
    base_local: u32,
    base_path: u32,
    point: u32,
    frame: u32,
    ctx: u32,
    element: bool,
    accept: Accept,
    /// The callee with no summary an acceptance rests on (§15 decision 2).
    assumed: []const u8 = "",
    prelim: ?struct { cause: Cause, detail: []const u8, approx: ?bool = null } = null,
    /// A value line's own verdict (§16.5).
    fixed: ?struct { verdict: Verdict, detail: []const u8, assumed: bool = false } = null,
    holders: []const Holder,
    /// The base's cells: what read-off makes W of (§16.3).
    cells: []const Entry = &.{},
    note: []const u8 = "",
    /// A probe's slot in `probe_ok`.
    probe: u32 = none,
    /// Where a call-site demand's W came from.
    origin: Origin = .exact,
    /// §18.4: the write needs exclusive contents that may share; decided
    /// after Dead, which names a live holder first.
    xfail: ?Rely = null,
    xdetail: []const u8 = "the elements of the list it was taken from may share one list",
    /// §18.8: a write of a capture, decided by the once closure `once_ci`.
    once_ci: u32 = none,
    /// §18.8: a once closure's creation demand: its own uses of what it
    /// captured are no later use.
    creation_ci: u32 = none,
    /// §20.6: a demand at a program constructor's entry, by its row.
    entry: ?EntryRow = null,
    /// §23.2: a send's demand, on every cell of its base; read off as `S`.
    deep: bool = false,
    /// §28.6: the edit's and the base's tokens, the top-level value a
    /// `top-level` rejection names, and the call or operand a `call` or
    /// `held-operand` one does.
    span: [2]u32 = .{ none, none },
    base_span: [2]u32 = .{ none, none },
    top: ?[3]u32 = null,
    via: u32 = none,
};

/// §20.2: what a platform's runtime does with the model it hands `update`.
const EntryRow = enum {
    /// browser-direct: hands it owned and keeps nothing (P1).
    direct,
    /// browser-tea, browser: keeps it, and skips by identity (Change 8).
    template,
};

/// Where a call-site demand's W came from: a summary's exact write, one
/// derived through an approximate step (a rejection is then the `call`
/// cause), or a pessimistic summary (the `limit` cause, §16.7).
const Origin = enum { exact, approx, limit };

const Pending = struct {
    av: AV,
    frame: u32,
    token: u32,
    is_ref: bool,
    by_call: bool,
    /// The summary of the call this operand waits for, and its index:
    /// it holds a cell only at paths that call touches (§16.4 item 2).
    consumer: ?*const Summary = null,
    arg: u32 = 0,
};

const CtxNode = struct { parent: u32, case_id: u32, arm: u32, depth: u32 };

/// A `Maybe.withDefault (Maybe.map m f) d` (§7.2 as amended for slice 3f):
/// the call, and the branch contexts of its `Just` and `Nothing` outcomes.
const MaybeJoin = struct { call: Inst.Index, just: u32, nothing: u32 };

const Frame = struct {
    /// The enclosing frame, or `none` for the declaration's.
    parent: u32,
    captures: std.ArrayList(Capture) = .empty,
    pending_base: usize,
    /// §26.2: what the `?`s of this frame return from it — each `Err`
    /// payload, under `Err` — joined into the frame's result.
    early: std.ArrayList(Entry) = .empty,
};

const PatSite = struct { list: Inst.Index, index: u32, spread: bool, scrut: AV = &.{} };

/// What the walk learns about a function-typed parameter (§16.2).
const FnState = struct {
    is_fn: bool = false,
    calls: Calls = .zero,
    need: bool = false,
    seen: bool = true,
    /// §23.3: handed on to a send position.
    send: u32 = none,
};

/// A supply to a function parameter, read off once its probe is resolved.
const SupplyRec = struct {
    fun: u32,
    k: u32,
    path: u32,
    av: AV,
    probe: u32,
    /// The callee's own `owned`, for a supply passed on (§16.4 item 4).
    owned: bool = true,
    /// The callee's own `approx`, when it supplies borrowed.
    approx: bool = false,
    /// The condition of what is supplied (§18.3).
    cond: u32 = cond_yes,
    /// A destructive supply, passed on (§18.5).
    taken: bool = false,
    /// A call inside a lambda (§18.9): the probe where the lambda made the
    /// call, beside `probe`, where the lambda was handed on.
    probe2: u32 = none,
};

/// §18.9: a call of the declaration's function parameter made inside a
/// lambda, in the lambda's vocabulary, which becomes a call of the
/// parameter wherever the lambda is checked.
const EnvCall = struct {
    closure: u32,
    j: u32,
    inst: Inst.Index,
    args: []const AV,
    probes: []const u32,
};

/// A summary or class being applied at a call.
const Callee = struct {
    sum: *const Summary,
    /// For notes: `Main.f`, `List.update`, `<lambda>`.
    name: []const u8,
    /// The operation of a call-site demand line.
    op: []const u8,
    /// A lambda's class: its closure, whose captures `◇` names.
    closure: u32 = none,
    /// A member of the recursive group being solved (§16.6).
    merge_fresh: bool = false,
};

const Walker = struct {
    o: *Ownership,
    m: u32,
    bir: *const Bir,
    decl: Bir.Decl,
    decl_index: u32,
    store: *TypeStore,
    inst_type: []const Var.Optional,
    local_type: []const Var.Optional,
    a: Allocator,
    mode: Mode,
    /// The declaration is in a recursive group (§16.6).
    recursive: bool = false,

    point: u32 = 0,
    cells: std.ArrayList(Cell) = .empty,
    cell_map: std.AutoHashMapUnmanaged([4]u32, u32) = .empty,
    local_av: []?AV = &.{},
    local_frame: []u32 = &.{},
    local_ctx: []u32 = &.{},
    pat_site: []?PatSite = &.{},
    frames: std.ArrayList(Frame) = .empty,
    frame: u32 = 0,
    ctx_nodes: std.ArrayList(CtxNode) = .empty,
    ctx: u32 = 0,
    cases: u32 = 0,
    /// §7.2 as amended for slice 3f: the `Maybe.withDefault (Maybe.map m f) d`
    /// being walked, and the context of each of its two outcomes.
    maybe_join: ?MaybeJoin = null,
    pending: std.ArrayList(Pending) = .empty,
    uses: std.ArrayList(Use) = .empty,
    demands: std.ArrayList(DemandRec) = .empty,
    escaped: std.ArrayList(Escape) = .empty,
    /// Esc by cell: the earliest point each cell escaped (§18.11).
    esc_index: std.AutoHashMapUnmanaged([4]u32, EscAt) = .empty,
    esc_heads: std.AutoHashMapUnmanaged([4]u32, u32) = .empty,
    closures: std.ArrayList(Closure) = .empty,
    /// Per instruction of the declaration: a lambda parameter's pattern's
    /// closure and position, `none` elsewhere.
    pat_closure: [][2]u32 = &.{},
    /// The declaration's parameters.
    params: []const Inst.Index = &.{},
    /// Per function parameter, then per function slot (§24.9): a function
    /// stored at a path of a parameter, `slot_keys[j - params.len]`.
    fn_state: std.ArrayList(FnState) = .empty,
    slot_keys: std.ArrayList([2]u32) = .empty,
    supplies: std.ArrayList(SupplyRec) = .empty,
    probe_ok: std.ArrayList(bool) = .empty,
    /// Per probe: failed for an approximate reason only.
    probe_approx: std.ArrayList(bool) = .empty,
    /// Per probe: its resolved line, for a once closure's report (§18.8).
    probe_info: std.ArrayList(?Demand) = .empty,
    result_av: AV = &.{},
    /// Per local: 1 for a local function of the `let` being created, 2 once
    /// it is named before its class exists (§16.5); 0 otherwise.
    early: []u8 = &.{},
    /// The writing top-level functions already reported out of sight: one
    /// line where each first leaves it (§16.5).
    unseen_funcs: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// §23.4: per instruction, whether it is the parameter pattern of a lambda
    /// written at a send position: a send value.
    send_params: []bool = &.{},
    /// `returnsOwned` reads only exact result entries: whether a failure was
    /// an approximate step's alone.
    ro_exact: bool = false,
    /// §18.2: the conditions, by index (`cond_yes`, `cond_lost` and
    /// `cond_shared` first), and the condition of each list cell that has
    /// one other than its kind's.
    conds: std.ArrayList(WCond) = .empty,
    cell_cond: std.ArrayList(u32) = .empty,
    cell_spine: std.ArrayList(u32) = .empty,
    /// §18.4: every atom relied on.
    reqs: std.ArrayList(Req) = .empty,
    /// Per call of a function parameter: its arguments, so that a cell made
    /// here and passed to the call is known to be what it may return.
    cb_args: []?AV = &.{},
    /// §18.4 item 4: per list-pattern element, its pattern — the scope of
    /// the split's taken cells.
    split_list: []u32 = &.{},
    split_scrut: []?AV = &.{},
    /// §18.9: calls of the declaration's function parameters inside lambdas.
    env_calls: std.ArrayList(EnvCall) = .empty,
    /// The record a program constructor with an entry row is handed: its
    /// functions are in sight there (§20.6), so storing them in it is not
    /// leaving the walk's sight.
    entry_arg: u32 = none,
    /// The uses by local, for `resolve` (§18.11).
    use_start: []u32 = &.{},
    use_order: []u32 = &.{},
    /// §20.4: wide values indexed by first step, by their slice.
    wide: std.AutoHashMapUnmanaged([2]usize, WideIndex) = .empty,
    /// §28.6, a report walk only: the first and last token of what is being
    /// evaluated, and of each instruction evaluated so far — what a message
    /// underlines.
    span: [2]u32 = .{ none, 0 },
    inst_span: [][2]u32 = &.{},
    /// The variable path a use being recorded reads, as written.
    use_at: [2]u32 = .{ none, none },

    // ---- setup -------------------------------------------------------------

    fn walkDecl(w: *Walker, body: Inst.Index) Allocator.Error!void {
        try w.o.seedPaths();
        const n = w.decl.locals_end - w.decl.locals_start;
        w.local_av = try w.a.alloc(?AV, n);
        @memset(w.local_av, null);
        w.local_frame = try w.a.alloc(u32, n);
        @memset(w.local_frame, 0);
        w.local_ctx = try w.a.alloc(u32, n);
        @memset(w.local_ctx, 0);
        w.pat_site = try w.a.alloc(?PatSite, n);
        @memset(w.pat_site, null);
        w.early = try w.a.alloc(u8, n);
        @memset(w.early, 0);
        const insts = w.decl.inst_end.int() - w.decl.inst_start.int();
        w.pat_closure = try w.a.alloc([2]u32, insts);
        w.cb_args = try w.a.alloc(?AV, insts);
        @memset(w.cb_args, null);
        w.split_list = try w.a.alloc(u32, insts);
        @memset(w.split_list, none);
        w.split_scrut = try w.a.alloc(?AV, insts);
        @memset(w.split_scrut, null);
        @memset(w.pat_closure, .{ none, none });
        w.send_params = try w.a.alloc(bool, insts);
        @memset(w.send_params, false);
        if (w.mode == .report) {
            w.inst_span = try w.a.alloc([2]u32, insts);
            @memset(w.inst_span, .{ none, none });
        }
        try w.ctx_nodes.append(w.a, .{ .parent = none, .case_id = none, .arm = 0, .depth = 0 });
        try w.frames.append(w.a, .{ .parent = none, .pending_base = 0 });
        try w.conds.appendSlice(w.a, &.{ .{}, .{ .no = 1 }, .{ .no = 2 } });
        w.params = w.bir.extraSlice(.{ .start = w.decl.params_start, .end = w.decl.params_end }, Inst.Index);
        try w.fn_state.appendNTimes(w.a, .{}, w.params.len);
        for (w.params, 0..) |p, i| {
            if (w.patternType(p)) |v| w.fn_state.items[i].is_fn = isFunc(w.store, v);
            try w.bindParam(p, 0);
        }
        const result = try w.withEarly(0, try w.eval(body));
        try w.consume(&.{body}, w.bir.insts.items(.main_token)[body.int()]);
        try w.sight(result, .{ .pending = "it is returned" }, w.token(body));
        w.result_av = result;
    }

    fn bindParam(w: *Walker, pat: Inst.Index, lambda: u32) Allocator.Error!void {
        const ty = w.patternType(pat);
        if (ty) |v| if (!try w.trackedVar(v)) return w.bindPattern(pat, &.{});
        const c = try w.cell(.{ .kind = .param, .a = pat.int(), .b = lambda, .ty = if (ty) |v| v.toOptional() else .none });
        const av = try w.a.dupe(Entry, &.{.{ .path = eps, .cell = c }});
        try w.bindPattern(pat, av);
    }

    fn patternType(w: *const Walker, pat: Inst.Index) ?Var {
        return switch (w.bir.instTag(pat)) {
            .pat_var => w.localType(w.bir.instData(pat).lhs),
            .pat_as => w.localType(w.bir.instData(pat).rhs),
            else => null,
        };
    }

    fn localType(w: *const Walker, l: u32) ?Var {
        if (l >= w.local_type.len) return null;
        return w.local_type[l].unwrap();
    }

    fn instType(w: *const Walker, inst: Inst.Index) ?Var {
        if (inst.int() >= w.inst_type.len) return null;
        return w.inst_type[inst.int()].unwrap();
    }

    /// A column over the declaration's instructions, at instruction `i`.
    fn instCol(w: *const Walker, comptime T: type, col: []const T, i: u32, default: T) T {
        const at = i -% w.decl.inst_start.int();
        return if (at < col.len) col[at] else default;
    }

    fn cell(w: *Walker, c: Cell) Allocator.Error!u32 {
        const key: [4]u32 = .{ @as(u32, @backingInt(c.kind)) | (@as(u32, @intFromBool(c.made)) << 8), c.a, c.b, c.path };
        const gop = try w.cell_map.getOrPut(w.a, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: u32 = @intCast(w.cells.items.len);
        gop.value_ptr.* = id;
        try w.cells.append(w.a, c);
        try w.cell_cond.append(w.a, none);
        try w.cell_spine.append(w.a, none);
        return id;
    }

    fn token(w: *const Walker, inst: Inst.Index) u32 {
        return w.bir.insts.items(.main_token)[inst.int()];
    }

    fn pos(w: *const Walker, tok: u32) Position {
        return w.o.in.positions.get(w.o.in.positions.ctx, w.m, tok);
    }

    // ---- abstract values ---------------------------------------------------

    /// Sorted and deduplicated, in place: every caller hands over an array
    /// of its own.
    fn norm(w: *Walker, items: []Entry) Allocator.Error!AV {
        _ = w;
        if (items.len <= 1) return items;
        std.mem.sort(Entry, items, {}, struct {
            fn less(_: void, x: Entry, y: Entry) bool {
                if (x.path != y.path) return x.path < y.path;
                if (x.cell != y.cell) return x.cell < y.cell;
                return x.approx < y.approx;
            }
        }.less);
        var n: usize = 1;
        for (items[1..]) |e| {
            const last = items[n - 1];
            if (last.path == e.path and last.cell == e.cell) continue;
            items[n] = e;
            n += 1;
        }
        return items[0..n];
    }

    fn unionOf(w: *Walker, parts: []const AV) Allocator.Error!AV {
        var all: std.ArrayList(Entry) = .empty;
        for (parts) |p| try all.appendSlice(w.a, p);
        return w.norm(all.items);
    }

    fn shift(w: *Walker, av: AV, s: Step) Allocator.Error!AV {
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *x| x.* = .{ .path = try w.o.prepend(s, e.path), .cell = e.cell, .approx = e.approx };
        return w.norm(out);
    }

    /// `av` placed under the path `p`.
    fn under(w: *Walker, av: AV, p: u32) Allocator.Error!AV {
        if (p == eps) return av;
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *x| x.* = .{ .path = try w.o.concat(p, e.path), .cell = e.cell, .approx = e.approx };
        return w.norm(out);
    }

    fn approxAll(w: *Walker, av: AV, inst: Inst.Index) Allocator.Error!AV {
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *x| x.* = .{ .path = e.path, .cell = e.cell, .approx = if (e.approx != 0) e.approx else inst.int() + 1 };
        return out;
    }

    /// A symbolic cell one step further down (§4.3).
    fn projCell(w: *Walker, c: u32, s: Step, ty: ?Var) Allocator.Error!?u32 {
        const x = w.cells.items[c];
        switch (x.kind) {
            .site, .closure, .func => return null,
            .top => return c,
            // What a definition made holds nothing its summary does not name.
            .shared => if (x.made) return null else {
                var y = x;
                y.path = try w.o.child(x.path, s.kind, s.arg);
                y.ty = if (ty) |v| v.toOptional() else .none;
                return try w.cell(y);
            },
            .param, .result, .env, .cbres, .taken, .payload => {
                var y = x;
                y.path = try w.o.child(x.path, s.kind, s.arg);
                y.ty = if (ty) |v| v.toOptional() else .none;
                return try w.cell(y);
            },
        }
    }

    fn proj(w: *Walker, av: AV, s: Step, ty: ?Var) Allocator.Error!AV {
        if (ty) |v| if (!try w.trackedVar(v)) return &.{};
        var out: std.ArrayList(Entry) = .empty;
        for (av) |e| {
            if (e.path == eps) {
                if (try w.projCell(e.cell, s, ty)) |c| try out.append(w.a, .{ .path = eps, .cell = c, .approx = e.approx });
                continue;
            }
            const first = w.o.firstStep(e.path).?;
            if (first.kind == .any) {
                try out.append(w.a, e);
            } else if (first.kind == s.kind and first.arg == s.arg) {
                try out.append(w.a, .{ .path = try w.o.dropFirst(e.path), .cell = e.cell, .approx = e.approx });
            }
        }
        return w.norm(out.items);
    }

    /// Every entry of `av` with closures expanded into what they capture,
    /// under `◇` (§4.2).
    fn expand(w: *Walker, av: AV) Allocator.Error!AV {
        // A value that holds no closure is its own expansion.
        for (av) |e| {
            if (w.cells.items[e.cell].kind == .closure) break;
        } else return av;
        var out: std.ArrayList(Entry) = .empty;
        var seen: std.ArrayList(u32) = .empty;
        try w.expandInto(av, eps, 0, &out, &seen);
        return w.norm(out.items);
    }

    fn expandInto(w: *Walker, av: AV, prefix: u32, approx: u32, out: *std.ArrayList(Entry), seen: *std.ArrayList(u32)) Allocator.Error!void {
        for (av) |e| {
            const path = try w.o.concat(prefix, e.path);
            const ap = if (approx != 0) approx else e.approx;
            try out.append(w.a, .{ .path = path, .cell = e.cell, .approx = ap });
            const c = w.cells.items[e.cell];
            if (c.kind != .closure) continue;
            if (std.mem.indexOfScalar(u32, seen.items, c.a) != null) continue;
            try seen.append(w.a, c.a);
            const at = try w.o.child(path, .env, 0);
            for (w.closures.items[c.a].captures) |cap| {
                const held = w.local_av[cap.local] orelse continue;
                const sub = try w.projPath(held, cap.path, null);
                try w.expandInto(sub, at, ap, out, seen);
            }
        }
    }

    /// `av` projected along every step of `p`.
    fn projPath(w: *Walker, av: AV, p: u32, ty: ?Var) Allocator.Error!AV {
        var buf: [k_limit + 1]Step = undefined;
        var at = av;
        const s = w.o.steps(p, &buf);
        var from: usize = 0;
        // A wide value projected again and again — an entry model (§20.4) —
        // is indexed by its first step once.
        if (s.len > 0 and av.len >= wide_index) {
            if (s.len == 1) if (ty) |v| if (!try w.trackedVar(v)) return &.{};
            at = try w.projFirst(av, s[0]);
            from = 1;
        }
        for (s[from..], from..) |st, i| at = try w.proj(at, st, if (i + 1 == s.len) ty else null);
        return at;
    }

    /// `proj(av, s)` for a wide value, through an index by first step that
    /// is built once per value: the same answer, without the scan.
    fn projFirst(w: *Walker, av: AV, s: Step) Allocator.Error!AV {
        const key: [2]usize = .{ @intFromPtr(av.ptr), av.len };
        const gop = try w.wide.getOrPut(w.a, key);
        if (!gop.found_existing) {
            var idx: WideIndex = .{};
            for (av) |e| {
                if (e.path == eps) {
                    try idx.roots.append(w.a, e);
                    continue;
                }
                const first = w.o.firstStep(e.path).?;
                if (first.kind == .any) {
                    try idx.any.append(w.a, e);
                    continue;
                }
                const g = try idx.by.getOrPut(w.a, .{ @backingInt(first.kind), first.arg });
                if (!g.found_existing) g.value_ptr.* = .empty;
                try g.value_ptr.append(w.a, .{ .path = try w.o.dropFirst(e.path), .cell = e.cell, .approx = e.approx });
            }
            gop.value_ptr.* = idx;
        }
        const idx = gop.value_ptr;
        var out: std.ArrayList(Entry) = .empty;
        for (idx.roots.items) |e| {
            if (try w.projCell(e.cell, s, null)) |c| try out.append(w.a, .{ .path = eps, .cell = c, .approx = e.approx });
        }
        try out.appendSlice(w.a, idx.any.items);
        if (idx.by.get(.{ @backingInt(s.kind), s.arg })) |list| try out.appendSlice(w.a, list.items);
        return w.norm(out.items);
    }

    // ---- exclusive contents (§18.2–§18.4) ---------------------------------

    fn mkCond(w: *Walker, atoms: []const WAtom) Allocator.Error!u32 {
        if (atoms.len == 0) return cond_yes;
        try w.conds.append(w.a, .{ .atoms = atoms });
        return @intCast(w.conds.items.len - 1);
    }

    fn atomCond(w: *Walker, t: WAtom) Allocator.Error!u32 {
        return w.mkCond(try w.a.dupe(WAtom, &.{t}));
    }

    fn sepCond(w: *Walker, x: u32, y: u32) Allocator.Error!u32 {
        return w.atomCond(if (x <= y) .{ .kind = .sep, .a = x, .b = y } else .{ .kind = .sep, .a = y, .b = x });
    }

    /// The conjunction of two conditions: failing exactly beats failing
    /// approximately, and a holding one rests on both atom sets.
    fn condAnd(w: *Walker, x: u32, y: u32) Allocator.Error!u32 {
        if (x == y or y == cond_yes) return x;
        if (x == cond_yes) return y;
        if (x == cond_shared or y == cond_shared) return cond_shared;
        if (x == cond_lost or y == cond_lost) return cond_lost;
        const xs = w.conds.items[x].atoms;
        const ys = w.conds.items[y].atoms;
        const all = try w.a.alloc(WAtom, xs.len + ys.len);
        @memcpy(all[0..xs.len], xs);
        @memcpy(all[xs.len..], ys);
        std.mem.sort(WAtom, all, {}, struct {
            fn less(_: void, p: WAtom, q: WAtom) bool {
                return p.less(q);
            }
        }.less);
        var n: usize = 0;
        for (all) |t| {
            if (n > 0 and std.meta.eql(all[n - 1], t)) continue;
            all[n] = t;
            n += 1;
        }
        if (n == xs.len) return x;
        if (n == ys.len) return y;
        return w.mkCond(all[0..n]);
    }

    /// The condition of a cell (§18.2): its table's, or its kind's — a cell
    /// that arrived from outside is as exclusive as its arrival is.
    fn cellCond(w: *Walker, c: u32) Allocator.Error!u32 {
        if (w.cell_cond.items[c] != none) return w.cell_cond.items[c];
        const x = w.cells.items[c];
        const k: u32 = switch (x.kind) {
            .site, .shared, .closure, .func => cond_yes,
            // A message: what its sender built, which the entry does not see (§20.5).
            .top, .payload => cond_lost,
            // A call's result: what instantiation set at its root; a result
            // no summary made has none, and is lost.
            .result => if (x.path != eps) blk: {
                var root = x;
                root.path = eps;
                root.ty = .none;
                break :blk try w.cellCond(try w.cell(root));
            } else cond_lost,
            .param, .env, .cbres => try w.atomCond(.{ .kind = .excl, .a = c }),
            // A taken element is as exclusive as its container (§18.5).
            // (a split element: as its scrutinee, §18.4 item 4).
            .taken => if (w.instCol(?AV, w.split_scrut, x.b, null)) |scrut| blk: {
                var k = cond_yes;
                for (scrut) |e| if (e.path == eps) {
                    k = try w.condAnd(k, try w.cellCond(e.cell));
                };
                break :blk k;
            } else try w.atomCond(.{ .kind = .excl, .a = try w.containerOf(c) }),
        };
        w.cell_cond.items[c] = k;
        return k;
    }

    /// Lower a cell's condition, as a write in place does (§18.2).
    fn lowerCond(w: *Walker, c: u32, k: u32) Allocator.Error!void {
        if (k == cond_yes) return;
        const now = try w.condAnd(try w.cellCond(c), k);
        w.cell_cond.items[c] = now;
    }

    /// The condition of a cell this walk made, which starts at `k`.
    fn initCond(w: *Walker, c: u32, k: u32) Allocator.Error!void {
        const cur = w.cell_cond.items[c];
        w.cell_cond.items[c] = if (cur != none) try w.condAnd(cur, k) else k;
    }

    /// Exclusivity of the represented containers, not of their contents.
    /// A list may hold shared read-only values without sharing its own array.
    fn cellSpine(w: *Walker, c: u32) Allocator.Error!u32 {
        if (w.cell_spine.items[c] != none) return w.cell_spine.items[c];
        const x = w.cells.items[c];
        const k: u32 = switch (x.kind) {
            .site, .closure, .func => cond_yes,
            .top, .payload, .shared => cond_lost,
            .result => if (x.path != eps) blk: {
                var root = x;
                root.path = eps;
                root.ty = .none;
                break :blk try w.cellSpine(try w.cell(root));
            } else cond_lost,
            .param, .env, .cbres => try w.atomCond(.{ .kind = .spine, .a = c }),
            .taken => try w.cellSpine(try w.takenBase(c)),
        };
        w.cell_spine.items[c] = k;
        return k;
    }

    fn initSpine(w: *Walker, c: u32, k: u32) Allocator.Error!void {
        const cur = w.cell_spine.items[c];
        w.cell_spine.items[c] = if (cur == none) k else try w.condAnd(cur, k);
    }

    fn lowerSpine(w: *Walker, c: u32, k: u32) Allocator.Error!void {
        if (k == cond_yes) return;
        w.cell_spine.items[c] = try w.condAnd(try w.cellSpine(c), k);
    }

    fn spineCond(w: *Walker, av: AV) Allocator.Error!u32 {
        var k = cond_yes;
        for (av) |e| if (e.path == eps) {
            k = try w.condAnd(k, try w.cellSpine(e.cell));
        };
        return k;
    }

    /// A returned container cannot also appear at another result position.
    fn spineAt(w: *Walker, av: AV, target: Entry) Allocator.Error!u32 {
        var k = try w.cellSpine(target.cell);
        for (av) |other| {
            if (other.path == target.path) continue;
            if (other.cell == target.cell) return cond_lost;
            if (w.o.isPrefix(other.path, target.path) or w.o.isPrefix(target.path, other.path)) continue;
            k = try w.condAnd(k, try w.sepSpines(target.cell, other.cell, target.approx == 0 and other.approx == 0));
        }
        return k;
    }

    fn sepSpines(w: *Walker, x: u32, y: u32, exact: bool) Allocator.Error!u32 {
        const cx = w.cells.items[x];
        if (x == y and w.inCoreDict()) switch (cx.kind) {
            .param, .env, .cbres => if (try w.o.dictTreePath(cx.path)) return w.cellSpine(x),
            else => {},
        };
        const k = try w.sepCells(x, y, exact);
        if (k <= cond_shared) return k;
        const atoms = try w.a.dupe(WAtom, w.conds.items[k].atoms);
        for (atoms) |*a| switch (a.kind) {
            .sep => a.kind = .sep_spine,
            .excl => a.kind = .spine,
            else => {},
        };
        return w.mkCond(atoms);
    }

    fn sepSpineValues(w: *Walker, x: AV, y: AV) Allocator.Error!u32 {
        var k = cond_yes;
        for (x) |e| {
            if (e.path != eps) continue;
            for (y) |f| if (f.path == eps) {
                k = try w.condAnd(k, try w.sepSpines(e.cell, f.cell, e.approx == 0 and f.approx == 0));
            };
        }
        return k;
    }

    /// The element cell a taken cell stands for, at its path.
    fn takenBase(w: *Walker, c: u32) Allocator.Error!u32 {
        const t = w.cells.items[c];
        if (t.kind != .taken) return c;
        if (t.path == eps) return t.a;
        var b = w.cells.items[t.a];
        b.path = try w.o.concat(b.path, t.path);
        b.ty = .none;
        return w.cell(b);
    }

    /// The container a taken element came out of: its base without the
    /// last `[*]`.
    fn containerOf(w: *Walker, c: u32) Allocator.Error!u32 {
        const t = w.cells.items[c];
        var b = w.cells.items[t.a];
        var buf: [k_limit + 1]Step = undefined;
        const s = w.o.steps(b.path, &buf);
        if (s.len == 0 or s[s.len - 1].kind != .elem) return t.a;
        var at: u32 = eps;
        for (s[0 .. s.len - 1]) |st| at = try w.o.child(at, st.kind, st.arg);
        b.path = at;
        b.ty = .none;
        return w.cell(b);
    }

    fn inCoreDict(w: *const Walker) bool {
        return w.o.in.packages[w.m] == .core and std.mem.eql(u8, w.o.in.module_names[w.m], "Dict");
    }

    fn madeHere(k: CellKind) bool {
        return k == .site or k == .result;
    }

    /// Whether two cells share no cell (§18.2).
    fn sepCells(w: *Walker, x: u32, y: u32, exact: bool) Allocator.Error!u32 {
        const cx = w.cells.items[x];
        const cy = w.cells.items[y];
        if (cx.kind == .closure or cx.kind == .func or cy.kind == .closure or cy.kind == .func) return cond_yes;
        // §20.8: inside core/Dict, one cell that arrived from outside at a
        // folded path of its tree stands for distinct positions, which the
        // module never makes share (the trusted surface, §20.9).
        if (x == y and w.inCoreDict()) switch (cx.kind) {
            .param, .env, .cbres => if (try w.o.dictTreePath(cx.path)) return w.cellCond(x),
            else => {},
        };
        if (x == y or (try w.covers(x, y)) != null or (try w.covers(y, x)) != null) {
            // Exact only when the text shows it: one place, not a list's
            // elements or a folded level standing for many (§8.4).
            const one = !(try w.o.representative(cx.path)) and !(try w.o.representative(cy.path));
            return if (exact and one) cond_shared else cond_lost;
        }
        if (cx.kind == .top or cy.kind == .top or cx.kind == .payload or cy.kind == .payload) return cond_lost;
        // A taken element and its container's other positions share no cell
        // when the container is exclusive (§18.5).
        if (cx.kind == .taken or cy.kind == .taken) {
            const t = if (cx.kind == .taken) x else y;
            const other = if (cx.kind == .taken) y else x;
            const base = try w.takenBase(t);
            // The container itself holds the taken element still.
            if (other != base and (try w.covers(other, base)) != null) return cond_lost;
            if (other == base or (try w.covers(base, other)) != null) return w.cellCond(t);
        }
        if (cx.kind == .shared or cy.kind == .shared) return cond_yes;
        if (madeHere(cx.kind) or madeHere(cy.kind)) {
            const made = if (madeHere(cx.kind)) x else y;
            const other = if (madeHere(cx.kind)) cy else cx;
            // A callback may return what it was handed.
            if (other.kind == .cbres) if (w.instCol(?AV, w.cb_args, other.b, null)) |args| {
                if ((try w.reaches(args, &.{.{ .path = eps, .cell = made }})) != null) return cond_lost;
            };
            return cond_yes;
        }
        return w.sepCond(x, y);
    }

    /// Whether two values share no cell.
    fn sepValues(w: *Walker, x: AV, y: AV) Allocator.Error!u32 {
        if (x.len == 0 or y.len == 0) return cond_yes;
        var k = cond_yes;
        // Only the cells matter, and whether each is reached exactly: a
        // value holding one cell at many paths is compared once (§20.4).
        const ex = try w.cellsOf(try w.expand(x));
        const ey = try w.cellsOf(try w.expand(y));
        for (ex) |a| for (ey) |b| {
            k = try w.condAnd(k, try w.sepCells(a.cell, b.cell, a.approx == 0 and b.approx == 0));
            if (k == cond_shared) return k;
        };
        return k;
    }

    /// `av`'s distinct cells, each at ε, exact when any entry reaches it exactly.
    fn cellsOf(w: *Walker, av: AV) Allocator.Error!AV {
        if (av.len <= 1) return av;
        const out = try w.a.alloc(Entry, av.len);
        for (av, out) |e, *o| o.* = .{ .path = eps, .cell = e.cell, .approx = e.approx };
        std.mem.sort(Entry, out, {}, struct {
            fn less(_: void, p: Entry, q: Entry) bool {
                if (p.cell != q.cell) return p.cell < q.cell;
                return p.approx < q.approx;
            }
        }.less);
        var n: usize = 1;
        for (out[1..]) |e| {
            if (e.cell == out[n - 1].cell) continue;
            out[n] = e;
            n += 1;
        }
        return out[0..n];
    }

    /// A value's deep condition (§18.2): every cell it holds, and no cell at
    /// two of its paths neither of which is a prefix of the other.
    fn deepCond(w: *Walker, av: AV) Allocator.Error!u32 {
        if (av.len == 0) return cond_yes;
        const ex = try w.expand(av);
        // A value this wide is not told apart cell by cell: the pairs are
        // quadratic, and the answer is the pessimistic one (§16.7's rule).
        if (ex.len > deep_cap) return cond_lost;
        var k = cond_yes;
        for (ex) |e| k = try w.condAnd(k, try w.cellCond(e.cell));
        for (ex, 0..) |e, i| for (ex[i + 1 ..]) |f| {
            if (w.o.isPrefix(e.path, f.path) or w.o.isPrefix(f.path, e.path)) continue;
            k = try w.condAnd(k, try w.sepCells(e.cell, f.cell, e.approx == 0 and f.approx == 0));
        };
        return k;
    }

    /// The condition of stored items, pairwise and against what the list
    /// already holds (§18.2's table).
    fn storedCond(w: *Walker, items: []const AV, elements: AV) Allocator.Error!u32 {
        var k = cond_yes;
        for (items, 0..) |v, i| {
            k = try w.condAnd(k, try w.deepCond(v));
            k = try w.condAnd(k, try w.sepValues(v, elements));
            for (items[i + 1 ..]) |u| k = try w.condAnd(k, try w.sepValues(v, u));
        }
        return k;
    }

    /// Relying on a condition (§18.4): its atoms become requirements of
    /// `frame`, or it fails.
    fn rely(w: *Walker, k: u32, frame: u32) Allocator.Error!Rely {
        if (k == cond_lost) return .approx;
        if (k == cond_shared) return .exact;
        const atoms = w.conds.items[k].atoms;
        for (atoms) |t| if (!w.ownedBy(t, frame)) return .approx;
        for (atoms) |t| try w.reqs.append(w.a, .{ .frame = frame, .atom = t });
        return .ok;
    }

    fn ownedBy(w: *Walker, t: WAtom, frame: u32) bool {
        return switch (t.kind) {
            .excl, .spine => w.atomCellIn(t.a, frame),
            .sep, .sep_spine => w.atomCellIn(t.a, frame) and w.atomCellIn(t.b, frame),
            .keep, .keep_spine => frame == 0 and w.atomCellIn(t.b, frame),
        };
    }

    /// Whether `frame` can state an atom about cell `c`: one of its own
    /// parameters, one of its captures, or the declaration's callback result.
    fn atomCellIn(w: *Walker, c: u32, frame: u32) bool {
        const x = w.cells.items[c];
        return switch (x.kind) {
            .param => if (x.b == 0) frame == 0 else if (w.lambdaParam(x)) |lp| w.closures.items[lp[0]].frame == frame else false,
            .cbres => frame == 0,
            .env => frame != 0,
            .taken => w.atomCellIn(x.a, frame),
            else => false,
        };
    }

    /// A condition in a summary's vocabulary (§18.3), for the frame whose
    /// parameters are `params`; `self`'s own `excl` is left to
    /// instantiation.
    fn xsumOf(w: *Walker, k: u32, frame: u32, params: []const Inst.Index, self: u32) Allocator.Error!XSum {
        if (k == cond_lost) return .{ .no = 1 };
        if (k == cond_shared) return .{ .no = 2 };
        const keep = w.o.keep.allocator();
        var out: std.ArrayList(XAtom) = .empty;
        for (w.conds.items[k].atoms) |t| {
            if ((t.kind == .excl or t.kind == .spine) and t.a == self) continue;
            const x = (try w.xatomOf(t, frame, params)) orelse return .{ .no = 1 };
            try out.append(keep, x);
        }
        return .{ .atoms = w.o.pruneAtoms(out.items) };
    }

    fn xatomOf(w: *Walker, t: WAtom, frame: u32, params: []const Inst.Index) Allocator.Error!?XAtom {
        if (t.kind == .keep or t.kind == .keep_spine) {
            if (frame != 0) return null;
            return .{ .kind = t.kind, .a = .{ .kind = .cb, .a = t.a, .path = t.path }, .b = (try w.atomProv(t.b, frame, params)) orelse return null };
        }
        const a = (try w.atomProv(t.a, frame, params)) orelse return null;
        return switch (t.kind) {
            .excl, .spine => .{ .kind = t.kind, .a = a },
            .sep, .sep_spine => blk: {
                var atom = sepAtom(a, (try w.atomProv(t.b, frame, params)) orelse return null);
                atom.kind = t.kind;
                break :blk atom;
            },
            .keep, .keep_spine => unreachable,
        };
    }

    fn atomProv(w: *Walker, c: u32, frame: u32, params: []const Inst.Index) Allocator.Error!?Prov {
        const x = w.cells.items[c];
        return switch (x.kind) {
            .param => if (w.paramIndex(x, frame, params)) |i| .{ .kind = .param, .a = i, .path = x.path } else null,
            .cbres => if (frame == 0) .{ .kind = .cb, .a = x.a, .path = x.path } else null,
            .env => if (frame != 0) .{ .kind = .env, .a = x.a, .path = x.path } else null,
            .taken => w.atomProv(try w.takenBase(c), frame, params),
            else => null,
        };
    }

    /// A summary's condition, instantiated at a call (§18.4).
    fn instXSum(w: *Walker, x: XSum, ctx: InstCtx) Allocator.Error!u32 {
        if (x.no == 1) return cond_lost;
        if (x.no == 2) return cond_shared;
        var k = cond_yes;
        for (x.atoms) |t| {
            const c = switch (t.kind) {
                .excl => try w.deepCond(try w.instProv(t.a, ctx)),
                .spine => try w.spineCond(try w.instProv(t.a, ctx)),
                .sep_spine => try w.sepSpineValues(try w.instProv(t.a, ctx), try w.instProv(t.b, ctx)),
                .keep_spine => try w.keepSpine(t.a.a, t.a.path, t.b, ctx),
                .sep => if (t.a.eql(t.b) and t.a.kind == .cb)
                    try w.freshAcross(t.a.a, ctx)
                else
                    try w.sepValues(try w.instProv(t.a, ctx), try w.instProv(t.b, ctx)),
                .keep => try w.keepShape(t.a.a, t.b, ctx),
            };
            k = try w.condAnd(k, c);
            if (k == cond_shared) return k;
        }
        return k;
    }

    /// `sep cb_j cb_j` at a call: two calls of the actual for `π_j` return no
    /// cell in common — every provenance of its result is made during the
    /// call, or the element the callee hands it destructively (§18.4).
    fn freshAcross(w: *Walker, j: u32, ctx: InstCtx) Allocator.Error!u32 {
        if (j >= ctx.avs.len) return cond_lost;
        const actual = ctx.avs[j];
        if (w.fnParamOf(actual)) |jj| {
            if (w.frame != 0) return cond_lost;
            const c = try w.cell(.{ .kind = .cbres, .a = jj, .b = ctx.inst.int() });
            return w.atomCond(.{ .kind = .sep, .a = c, .b = c });
        }
        const classes = try w.classesOf(actual);
        if (classes.len == 0) return cond_lost;
        var k = cond_yes;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return cond_lost;
            if (c.limit != .none) return cond_lost;
            for (c.res) |r| switch (r.prov.kind) {
                .fresh, .esc => {},
                .param => k = try w.condAnd(k, try w.takenSupply(j, r.prov, ctx)),
                else => return cond_lost,
            };
        }
        return k;
    }

    /// Whether what callee `ctx.s` supplies the actual for `π_j` at the
    /// class's parameter `p` is only ever an element taken destructively:
    /// a different one at every call, as exclusive as its container.
    fn takenSupply(w: *Walker, j: u32, p: Prov, ctx: InstCtx) Allocator.Error!u32 {
        var k = cond_yes;
        var any = false;
        for (ctx.s.supply) |e| {
            if (e.fun != j or e.k != p.a or !w.o.overlap(e.path, p.path)) continue;
            if (!e.prov.taken) return cond_lost;
            any = true;
            k = try w.condAnd(k, try w.instXSum(e.xc, ctx));
        }
        return if (any) k else cond_lost;
    }

    /// `keep cb_j c` at a call (the thesis's "keeps shape", §18.5): the
    /// actual for `π_j`, handed an element of `container` destructively,
    /// returns cells made during the call, or the element's own at the same
    /// path, and is exclusive inside.
    fn keepShape(w: *Walker, j: u32, container: Prov, ctx: InstCtx) Allocator.Error!u32 {
        if (j >= ctx.avs.len) return cond_lost;
        const actual = ctx.avs[j];
        if (w.fnParamOf(actual)) |jj| {
            if (w.frame != 0) return cond_lost;
            var k = cond_yes;
            for (try w.instProv(container, ctx)) |e| {
                if (e.path != eps) continue;
                k = try w.condAnd(k, try w.atomCond(.{ .kind = .keep, .a = jj, .b = e.cell }));
            }
            return k;
        }
        const classes = try w.classesOf(actual);
        if (classes.len == 0) return cond_lost;
        var k = cond_yes;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return cond_lost;
            if (c.limit != .none) return cond_lost;
            for (c.res) |r| switch (r.prov.kind) {
                .fresh => {},
                .param => {
                    if (r.path != r.prov.path) return cond_lost;
                    k = try w.condAnd(k, try w.takenSupply(j, r.prov, ctx));
                },
                else => return cond_lost,
            };
        }
        // And exclusive inside: the result as the call instantiates it.
        return w.condAnd(k, try w.deepCond(try w.instProv(.{ .kind = .cb, .a = j }, ctx)));
    }

    /// Focus restores one selected container. Its contents need not be owned,
    /// but its root must be fresh or the root taken at that same result path.
    fn keepSpine(w: *Walker, j: u32, path: u32, container: Prov, ctx: InstCtx) Allocator.Error!u32 {
        const actual = (try w.actualOf(ctx.s, ctx.avs, j)) orelse return cond_lost;
        if (w.fnParamOf(actual)) |jj| {
            if (w.frame != 0) return cond_lost;
            var k = cond_yes;
            for (try w.instProv(container, ctx)) |e| if (e.path == eps) {
                k = try w.condAnd(k, try w.atomCond(.{ .kind = .keep_spine, .a = jj, .b = e.cell, .path = path }));
            };
            return k;
        }
        const classes = try w.classesOf(actual);
        if (classes.len == 0) return cond_lost;
        var k = cond_yes;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return cond_lost;
            if (c.coarse or c.limit != .none) return cond_lost;
            for (c.res) |r| {
                if (r.path != path) {
                    if (w.o.isPrefix(r.path, path)) return cond_lost;
                    continue;
                }
                switch (r.prov.kind) {
                    .fresh => {},
                    .param => {
                        if (r.prov.path != path) return cond_lost;
                        for (c.uses) |u| if (u.param == r.prov.a and u.bits & (bit_e | bit_j) != 0 and w.o.overlap(u.path, r.prov.path)) return cond_lost;
                        var found = false;
                        for (ctx.s.supply) |e| {
                            if (e.fun != j or e.k != r.prov.a or !e.owned or !e.prov.taken or !w.o.isPrefix(e.path, path)) continue;
                            found = true;
                            const tail = (try w.o.suffix(e.path, path)) orelse return cond_lost;
                            var p = e.prov;
                            p.path = try w.o.concat(p.path, tail);
                            k = try w.condAnd(k, try w.spineCond(try w.instProv(p, ctx)));
                        }
                        if (!found) return cond_lost;
                    },
                    else => return cond_lost,
                }
                // A replacement also stored at another position is not a transfer.
                for (c.res) |other| if (other.path != path and other.prov.eql(r.prov)) return cond_lost;
            }
        }
        const cb = Prov{ .kind = .cb, .a = j, .path = path };
        return w.condAnd(k, try w.spineCond(try w.instProv(cb, ctx)));
    }

    // ---- uses, pending, escape -------------------------------------------

    /// The local and path an expression names, when it is a variable or a
    /// field path of one (§7.1).
    fn refPath(w: *Walker, inst: Inst.Index) Allocator.Error!?Capture {
        const tag = w.bir.instTag(inst);
        const data = w.bir.instData(inst);
        switch (tag) {
            .local => return .{ .local = data.lhs, .path = eps },
            .field_access => {
                const base = (try w.refPath(@fromBackingInt(@intCast(data.lhs)))) orelse return null;
                const sym = w.bir.symbol(@fromBackingInt(@intCast(data.rhs)));
                return .{ .local = base.local, .path = try w.o.child(base.path, .field, @backingInt(sym)) };
            },
            .tuple_index => {
                const base = (try w.refPath(@fromBackingInt(@intCast(data.lhs)))) orelse return null;
                return .{ .local = base.local, .path = try w.o.child(base.path, .tuple, data.rhs) };
            },
            else => return null,
        }
    }

    /// Record the uses a consumer makes of its operands, at a new point.
    fn consume(w: *Walker, operands: []const Inst.Index, tok: u32) Allocator.Error!void {
        w.point += 1;
        for (operands) |op| try w.useOperand(op, tok, &.{});
    }

    fn useOperand(w: *Walker, op: Inst.Index, tok: u32, except: []const u32) Allocator.Error!void {
        if (try w.refPath(op)) |r| {
            // §28.6: the path as written, for a message.
            w.use_at = .{ w.rootToken(op), w.token(op) };
            defer w.use_at = .{ none, none };
            try w.useAt(r.local, r.path, tok, except);
        }
    }

    fn useAt(w: *Walker, l: u32, path: u32, tok: u32, except: []const u32) Allocator.Error!void {
        // A local of this frame, or one this frame captured from an
        // enclosing one: a closure that gave up what it captured must not
        // read it again (§18.8, §23.7).
        if (l >= w.local_frame.len) return;
        if (w.local_frame[l] != w.frame and (w.local_av[l] == null or !w.inFrameOf(w.local_frame[l]))) return;
        try w.uses.append(w.a, .{ .local = l, .path = path, .except = except, .point = w.point, .frame = w.frame, .ctx = w.ctx, .token = tok, .at = w.use_at });
    }

    /// The first token of a variable path: its root local's.
    fn rootToken(w: *const Walker, inst: Inst.Index) u32 {
        var at = inst;
        var depth: u32 = 0;
        while (depth < 64) : (depth += 1) switch (w.bir.instTag(at)) {
            .field_access, .tuple_index => at = @fromBackingInt(@intCast(w.bir.instData(at).lhs)),
            else => break,
        };
        return w.token(at);
    }

    /// Record, at the current point, a use of everything a closure value
    /// in `av` captured (§6.1 item 1): a temporary closure consumed by a call.
    fn useCaptures(w: *Walker, av: AV, tok: u32) Allocator.Error!void {
        for (av) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind != .closure) continue;
            for (w.closures.items[c.a].captures) |cap| {
                if (cap.local >= w.local_frame.len or w.local_frame[cap.local] != w.frame) continue;
                try w.uses.append(w.a, .{ .local = cap.local, .path = cap.path, .point = w.point, .frame = w.frame, .ctx = w.ctx, .token = tok, .via = c.a });
            }
        }
    }

    /// `useCaptures` for each operand that is not a variable path: a
    /// variable holding a closure is a holder of its own, used at the call.
    fn useTemporaries(w: *Walker, insts: []const Inst.Index, avs: []const AV, tok: u32) Allocator.Error!void {
        for (insts, avs) |inst, av| {
            if ((try w.refPath(inst)) != null) continue;
            try w.useCaptures(av, tok);
        }
    }

    fn pushPending(w: *Walker, av: AV, inst: Inst.Index, by_call: bool) Allocator.Error!void {
        const is_ref = (try w.refPath(inst)) != null;
        try w.pending.append(w.a, .{ .av = av, .frame = w.frame, .token = w.token(inst), .is_ref = is_ref, .by_call = by_call });
    }

    fn popPending(w: *Walker, n: usize) void {
        w.pending.shrinkRetainingCapacity(w.pending.items.len - n);
    }

    /// Evaluate operands left to right; each is pending until the consumer
    /// runs (§7.4). The caller pops them.
    fn evalOperands(w: *Walker, insts: []const Inst.Index, by_call: bool) Allocator.Error![]AV {
        const out = try w.a.alloc(AV, insts.len);
        for (insts, out) |inst, *v| {
            v.* = try w.eval(inst);
            try w.pushPending(v.*, inst, by_call);
        }
        return out;
    }

    fn escape(w: *Walker, av: AV, at: u32) Allocator.Error!void {
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try w.noteEscape(e.cell, at, 0);
        }
    }

    /// §18.6: a function value handed to a `foreign` with no summary escapes
    /// what it captured — the foreign may keep it and call it later. Marked
    /// with the call, so that a rejection through it says so.
    fn escapeCapturesOf(w: *Walker, av: AV, at: u32, call: Inst.Index) Allocator.Error!void {
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            if (!w.o.hasStep(e.path, .env)) continue;
            try w.noteEscape(e.cell, at, call.int() + 1);
        }
    }

    /// The escape of §18.6, through a callee's summary (its `J`).
    fn escapeWhy(w: *Walker, av: AV, at: u32, call: Inst.Index) Allocator.Error!void {
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try w.noteEscape(e.cell, at, call.int() + 1);
        }
    }

    fn escKey(x: Cell, path: u32) [4]u32 {
        return .{ @backingInt(x.kind), x.a, x.b, path };
    }

    /// Join `c` to Esc at `at` (§4.3), in the list and in the index by cell
    /// that `escapedBefore` reads.
    fn noteEscape(w: *Walker, c: u32, at: u32, why: u32) Allocator.Error!void {
        const key = escKey(w.cells.items[c], w.cells.items[c].path);
        const head = try w.esc_heads.getOrPut(w.a, key);
        const previous = if (head.found_existing) head.value_ptr.* else none;
        const event: u32 = @intCast(w.escaped.items.len);
        try w.escaped.append(w.a, .{ .cell = c, .point = at, .why = why, .ctx = w.ctx, .prev = previous });
        head.value_ptr.* = event;
        const gop = try w.esc_index.getOrPut(w.a, escKey(w.cells.items[c], w.cells.items[c].path));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const e = gop.value_ptr;
        if (why == 0) {
            e.gen = @min(e.gen, at);
        } else if (at < e.js) {
            e.js = at;
            e.why = why;
        }
    }

    /// The earliest escapes of `c` — of it, or of a cell that stands for it
    /// (§4.3: a symbolic cell stands for everything under it).
    fn escapeOf(w: *Walker, c: u32) Allocator.Error!EscAt {
        var out: EscAt = .{};
        for ([_]u32{ c, try w.takenBase(c) }) |cc| {
            const x = w.cells.items[cc];
            const symbolic = switch (x.kind) {
                .param, .result, .env, .shared, .cbres, .taken, .payload => true,
                else => false,
            };
            var at = x.path;
            while (true) {
                if (w.esc_index.get(escKey(x, at))) |e| {
                    out.gen = @min(out.gen, e.gen);
                    if (e.js < out.js) {
                        out.js = e.js;
                        out.why = e.why;
                    }
                }
                if (!symbolic or at == eps) break;
                at = w.o.paths.parent.items[at];
            }
        }
        return out;
    }

    /// Unescaped at a demand: an alternative arm cannot retain its cell.
    /// Summary read-off deliberately keeps escapeOf's union of every arm.
    fn escapeBefore(w: *Walker, c: u32) Allocator.Error!EscAt {
        var out: EscAt = .{};
        for ([_]u32{ c, try w.takenBase(c) }) |cc| {
            const x = w.cells.items[cc];
            const symbolic = switch (x.kind) {
                .param, .result, .env, .shared, .cbres, .taken, .payload => true,
                else => false,
            };
            var path = x.path;
            while (true) {
                var event = w.esc_heads.get(escKey(x, path)) orelse none;
                while (event != none) {
                    const e = w.escaped.items[event];
                    if (e.point < w.point and w.compatible(e.ctx, w.ctx)) {
                        if (e.why == 0) {
                            out.gen = @min(out.gen, e.point);
                        } else if (e.point < out.js) {
                            out.js = e.point;
                            out.why = e.why;
                        }
                    }
                    event = e.prev;
                }
                if (!symbolic or path == eps) break;
                path = w.o.paths.parent.items[path];
            }
        }
        return out;
    }

    fn isEscaped(w: *Walker, c: u32) Allocator.Error!bool {
        const e = try w.escapeOf(c);
        return e.gen != none or e.js != none;
    }

    // ---- branch contexts ---------------------------------------------------

    fn compatible(w: *const Walker, x: u32, y: u32) bool {
        var a = x;
        var b = y;
        var prev_a: u32 = none;
        var prev_b: u32 = none;
        while (w.ctx_nodes.items[a].depth > w.ctx_nodes.items[b].depth) {
            prev_a = a;
            a = w.ctx_nodes.items[a].parent;
        }
        while (w.ctx_nodes.items[b].depth > w.ctx_nodes.items[a].depth) {
            prev_b = b;
            b = w.ctx_nodes.items[b].parent;
        }
        while (a != b) {
            prev_a = a;
            prev_b = b;
            a = w.ctx_nodes.items[a].parent;
            b = w.ctx_nodes.items[b].parent;
        }
        if (prev_a == none or prev_b == none) return true;
        const na = w.ctx_nodes.items[prev_a];
        const nb = w.ctx_nodes.items[prev_b];
        return !(na.case_id == nb.case_id and na.arm != nb.arm);
    }

    // ---- binding -------------------------------------------------------------

    fn bindLocal(w: *Walker, l: u32, av: AV) void {
        if (l >= w.local_av.len) return;
        // §26.1: a local index is bound once per walk. Lowering gives every
        // binder — written or compiler-made — an index of its own, and BIR
        // is a tree, so no binder is walked twice; a local function group's
        // rounds restore `local_av` before walking again (`restore`). Were
        // one bound twice, a holder found through the first binding could
        // have its later reads resolved against the second.
        if (std.debug.runtime_safety) std.debug.assert(w.local_av[l] == null);
        w.local_av[l] = av;
        w.local_frame[l] = w.frame;
        w.local_ctx[l] = w.ctx;
    }

    fn bindPattern(w: *Walker, pat: Inst.Index, av: AV) Allocator.Error!void {
        const b = w.bir;
        const data = b.instData(pat);
        switch (b.instTag(pat)) {
            .pat_var => w.bindLocal(data.lhs, av),
            .pat_as => {
                w.bindLocal(data.rhs, av);
                try w.bindPattern(@fromBackingInt(@intCast(data.lhs)), av);
            },
            .pat_tuple => for (b.extraSlice(Bir.inlineRange(data), Inst.Index), 0..) |el, i| {
                try w.bindPattern(el, try w.proj(av, .{ .kind = .tuple, .arg = @intCast(i) }, w.patternType(el)));
            },
            .pat_record => for (b.extraSlice(Bir.inlineRange(data), u32)) |l| {
                const name = b.locals[w.decl.locals_start + l].name;
                const sym = if (name.unwrap()) |s| @backingInt(b.symbols[s]) else 0;
                w.bindLocal(l, try w.proj(av, .{ .kind = .field, .arg = sym }, w.localType(l)));
            },
            .pat_ctor => {
                const c = try w.ctorOf(@fromBackingInt(@intCast(data.lhs)));
                for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index), 0..) |arg, i| {
                    try w.bindPattern(arg, try w.proj(av, .{ .kind = .ctor, .arg = c *% 64 +% @as(u32, @intCast(i)) }, w.patternType(arg)));
                }
            },
            .pat_list => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                for (items, 0..) |item, i| {
                    if (b.instTag(item) == .pat_spread) {
                        // A spread binds a view of the scrutinee: the same cells.
                        const inner: Inst.Index = @fromBackingInt(@intCast(b.instData(item).lhs));
                        try w.bindPattern(inner, av);
                        if (b.instTag(inner) == .pat_var) w.notePat(b.instData(inner).lhs, pat, i, true, av);
                    } else {
                        // §18.4 item 4, the split: an element a list pattern
                        // binds is that position, taken — apart from the
                        // pattern's other bindings when the scrutinee is
                        // exclusive, and held by every other holder of it.
                        const el = try w.proj(av, .{ .kind = .elem, .arg = 0 }, w.patternType(item));
                        const out = try w.a.alloc(Entry, el.len);
                        for (el, out) |e, *x| {
                            x.* = e;
                            if (e.path != eps) continue;
                            switch (w.cells.items[e.cell].kind) {
                                .param, .result, .env, .cbres => x.cell = try w.cell(.{ .kind = .taken, .a = e.cell, .b = item.int() }),
                                else => {},
                            }
                        }
                        w.split_list[item.int() - w.decl.inst_start.int()] = pat.int();
                        w.split_scrut[item.int() - w.decl.inst_start.int()] = av;
                        try w.bindPattern(item, try w.norm(out));
                        if (b.instTag(item) == .pat_var) w.notePat(b.instData(item).lhs, pat, i, false, av);
                    }
                }
            },
            .pat_spread => try w.bindPattern(@fromBackingInt(@intCast(data.lhs)), av),
            else => {},
        }
    }

    fn notePat(w: *Walker, l: u32, list: Inst.Index, index: usize, spread: bool, scrut: AV) void {
        if (l < w.pat_site.len) w.pat_site[l] = .{ .list = list, .index = @intCast(index), .spread = spread, .scrut = scrut };
    }

    /// A small id for a constructor reference, for its path step.
    fn ctorOf(w: *Walker, ref: Inst.Index) Allocator.Error!u32 {
        const data = w.bir.instData(ref);
        switch (w.bir.instTag(ref)) {
            .ctor => return w.o.ctorId(w.m, data.lhs),
            .ext_ctor => {
                if (data.lhs >= w.o.in.provenance.len) return w.o.ctorId(data.lhs, none);
                const i = w.o.in.provenance[data.lhs].ctorIndex(data.rhs) orelse none;
                return w.o.ctorId(data.lhs, i);
            },
            else => return w.o.ctorId(none, ref.int()),
        }
    }

    // ---- callees ---------------------------------------------------------

    const Target = struct { m: u32, d: u32 };

    fn valueTarget(w: *const Walker, inst: Inst.Index) ?Target {
        const data = w.bir.instData(inst);
        switch (w.bir.instTag(inst)) {
            .top => return .{ .m = w.m, .d = data.lhs },
            .ext_value => {
                if (data.lhs >= w.o.in.provenance.len) return null;
                const d = w.o.in.provenance[data.lhs].valueDecl(data.rhs) orelse return null;
                return .{ .m = data.lhs, .d = d.int() };
            },
            else => return null,
        }
    }

    fn termTarget(w: *const Walker, t: Dispatch.Term) ?Target {
        switch (t) {
            .top => |x| return .{ .m = w.m, .d = x.decl.int() },
            .ext => |x| {
                const m2 = x.module.int();
                if (m2 >= w.o.in.provenance.len) return null;
                const d = w.o.in.provenance[m2].valueDecl(@backingInt(x.value)) orelse return null;
                return .{ .m = m2, .d = d.int() };
            },
            else => return null,
        }
    }

    fn methodTarget(w: *const Walker, inst: Inst.Index) ?Target {
        if (w.m >= w.o.in.dispatch.len) return null;
        const dt = &w.o.in.dispatch[w.m];
        const site = dt.siteOf(inst) orelse return null;
        const ci = site.callee.unwrap() orelse return null;
        return w.termTarget(dt.term(ci));
    }

    fn targetName(w: *const Walker, t: Target) []const u8 {
        const b = w.o.in.birs[t.m];
        return w.o.in.interner.slice(b.symbol(b.decls[t.d].name));
    }

    fn qualified(w: *Walker, t: Target) Allocator.Error![]const u8 {
        const key = (@as(u64, t.m) << 32) | t.d;
        if (w.o.names_memo.get(key)) |n| return n;
        const n = try w.qualifiedRaw(t);
        try w.o.names_memo.put(w.o.in.gpa, key, n);
        return n;
    }

    fn qualifiedRaw(w: *Walker, t: Target) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(w.o.out.allocator(), "{s}.{s}", .{ w.o.in.module_names[t.m], w.targetName(t) });
    }

    fn isCore(w: *const Walker, t: Target, module: []const u8) bool {
        return w.o.in.packages[t.m] == .core and std.mem.eql(u8, w.o.in.module_names[t.m], module);
    }

    /// The named writers of §3.1, whose call-site demands keep their
    /// slice-1 operation, `List.<name>`.
    fn writerName(w: *const Walker, t: Target) ?[]const u8 {
        if (!w.isCore(t, "List")) return null;
        const name = w.targetName(t);
        // Not `cons`: a prepend copies its base and writes nothing (§3.1,
        // amended for slice 3f).
        const writers = [_][]const u8{ "set", "update", "push", "pop", "swap", "insertAt", "removeAt", "append" };
        for (writers) |x| if (std.mem.eql(u8, x, name)) return x;
        return null;
    }

    /// A `foreign` whose rung is `impure` or `suspends` (§6.1 item 2). A
    /// `foreign pure` promises it changes and keeps nothing, so it is a
    /// conservative call: it can only return what it was given.
    fn escapes(w: *const Walker, t: Target) bool {
        const d = w.o.in.birs[t.m].decls[t.d];
        return d.kind == .foreign_value and d.rung != .pure;
    }

    fn isSpreadCall(w: *const Walker, inst: Inst.Index) bool {
        if (w.bir.instTag(inst) != .call) return false;
        const tags = w.o.in.spans[w.m].tags;
        const tok = w.token(inst);
        if (tok >= tags.len or tags[tok] != .ellipsis) return false;
        const t = w.valueTarget(@fromBackingInt(@intCast(w.bir.instData(inst).lhs))) orelse return false;
        if (!w.isCore(t, "List")) return false;
        const name = w.targetName(t);
        return std.mem.eql(u8, name, "cons") or std.mem.eql(u8, name, "append");
    }

    fn isSpreadAppend(w: *const Walker, inst: Inst.Index) bool {
        const t = w.valueTarget(@fromBackingInt(@intCast(w.bir.instData(inst).lhs))) orelse return false;
        return std.mem.eql(u8, w.targetName(t), "append");
    }

    fn isListAppend(w: *const Walker, inst: Inst.Index) bool {
        if (w.bir.instTag(inst) != .call) return false;
        if (w.m >= w.o.in.dispatch.len) return false;
        const dt = &w.o.in.dispatch[w.m];
        if (dt.isListAppend(inst) or dt.isListAppend(@fromBackingInt(@intCast(w.bir.instData(inst).lhs)))) {
            return w.callArgs(inst).len == 2;
        }
        return false;
    }

    fn callArgs(w: *const Walker, inst: Inst.Index) []const Inst.Index {
        return w.bir.extraSlice(w.bir.subRange(@fromBackingInt(@intCast(w.bir.instData(inst).rhs))), Inst.Index);
    }

    /// Whether the tokens strictly between `a` and `b` are balanced brackets.
    fn balanced(w: *const Walker, a: u32, b: u32) bool {
        const tags = w.o.in.spans[w.m].tags;
        var depth: i32 = 0;
        var i = a + 1;
        while (i < b and i < tags.len) : (i += 1) {
            switch (tags[i]) {
                .l_bracket, .l_paren, .l_brace => depth += 1,
                .r_bracket, .r_paren, .r_brace => {
                    depth -= 1;
                    if (depth < 0) return false;
                },
                else => {},
            }
        }
        return depth == 0;
    }

    // ---- evaluation (§5) -------------------------------------------------

    fn eval(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        if (w.mode != .report) return w.evalRaw(inst);
        // §28.6: the tokens each instruction spans, for the messages.
        const tok = w.token(inst);
        const outer = w.span;
        w.span = .{ tok, tok };
        const out = try w.evalRaw(inst);
        // A variable path is read without its root being evaluated.
        switch (w.bir.instTag(inst)) {
            .field_access, .tuple_index => w.span[0] = @min(w.span[0], w.rootToken(inst)),
            else => {},
        }
        const mine = w.span;
        w.setSpan(inst, mine);
        w.span = .{ @min(outer[0], mine[0]), if (outer[0] == none) mine[1] else @max(outer[1], mine[1]) };
        return out;
    }

    fn setSpan(w: *Walker, inst: Inst.Index, s: [2]u32) void {
        const i = inst.int() -% w.decl.inst_start.int();
        if (i < w.inst_span.len) w.inst_span[i] = s;
    }

    /// The tokens instruction `inst` spans, once a report walk evaluated it.
    fn spanOf(w: *const Walker, inst: Inst.Index) ?[2]u32 {
        const i = inst.int() -% w.decl.inst_start.int();
        if (i >= w.inst_span.len or w.inst_span[i][0] == none) return null;
        return w.inst_span[i];
    }

    fn evalRaw(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        switch (b.instTag(inst)) {
            .local => return w.evalLocal(data.lhs, eps, inst),
            .field_access, .tuple_index => {
                if (try w.refPath(inst)) |r| return w.evalLocal(r.local, r.path, inst);
                const target = try w.eval(@fromBackingInt(@intCast(data.lhs)));
                const s: Step = if (b.instTag(inst) == .field_access)
                    .{ .kind = .field, .arg = @backingInt(b.symbol(@fromBackingInt(@intCast(data.rhs)))) }
                else
                    .{ .kind = .tuple, .arg = data.rhs };
                return w.proj(target, s, w.instType(inst));
            },
            .top, .ext_value => {
                const t = w.valueTarget(inst) orelse return &.{};
                const decl = w.o.in.birs[t.m].decls[t.d];
                // A function: a value with no cell of its own, which carries
                // its summary to where it is called (§16.5).
                if (decl.params > 0) return w.single(.{ .kind = .func, .a = t.m, .b = t.d });
                if (!try w.isTracked(inst)) return &.{};
                if (decl.kind == .foreign_value) return w.single(.{ .kind = .top, .a = 0 });
                // What is shared is the cells the definition makes, and
                // nothing else (thesis §3.10): `Dict.empty` makes none (T51).
                if (try w.o.ensureSummary(t.m, t.d)) |s| return w.sharedOf(s, t, inst);
                return w.single(.{ .kind = .shared, .a = t.m, .b = t.d, .ty = w.instTypeOpt(inst) });
            },
            .ctor, .ext_ctor => return (try w.constructorValue(inst)) orelse &.{},
            .int, .float, .char, .string, .chunk, .unit, .@"error" => return &.{},
            .interp => {
                const parts = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(parts, false);
                w.popPending(avs.len);
                try w.consume(parts, w.token(inst));
                return &.{};
            },
            .tuple => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(items, false);
                w.popPending(avs.len);
                try w.consume(items, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (avs, 0..) |av, i| parts[i] = try w.shift(av, .{ .kind = .tuple, .arg = @intCast(i) });
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a tuple" }, w.token(inst));
                return out;
            },
            .list => {
                const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
                const avs = try w.evalOperands(items, false);
                w.popPending(avs.len);
                try w.consume(items, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len + 1);
                parts[0] = try w.single(.{ .kind = .site, .a = inst.int(), .ty = w.instTypeOpt(inst) });
                // §18.2: a literal's items, each exclusive and pairwise apart.
                try w.initCond(parts[0][0].cell, try w.storedCond(avs, &.{}));
                for (avs, 0..) |av, i| parts[i + 1] = try w.shift(av, .{ .kind = .elem, .arg = 0 });
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a list" }, w.token(inst));
                return out;
            },
            .record => {
                const fields = b.extraSlice(Bir.inlineRange(data), Bir.Field);
                const insts = try w.a.alloc(Inst.Index, fields.len);
                for (fields, insts) |f, *x| x.* = f.value;
                const avs = try w.evalOperands(insts, false);
                w.popPending(avs.len);
                try w.consume(insts, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (fields, avs, 0..) |f, av, i| parts[i] = try w.shift(av, .{ .kind = .field, .arg = @backingInt(b.symbol(f.name)) });
                const out = try w.unionOf(parts);
                if (inst.int() != w.entry_arg) try w.sight(out, .{ .pending = "it is stored in a record" }, w.token(inst));
                return out;
            },
            .record_update => return w.evalRecordUpdate(inst),
            .call => return w.evalCall(inst),
            .method_call => return w.evalMethod(inst),
            .type_dispatch => {
                const md = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.TypeDispatch);
                const args = b.extraSlice(.{ .start = md.args_start, .end = md.args_end }, Inst.Index);
                return w.conservative(inst, args, &.{}, null, "", false);
            },
            .lambda => {
                const params = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Inst.Index);
                return w.closure(params, @fromBackingInt(@intCast(data.rhs)), null);
            },
            .let => return w.evalLet(inst),
            .case => return w.evalCase(inst),
            .@"try" => {
                const s = try w.eval(@fromBackingInt(@intCast(data.lhs)));
                try w.consume(&.{@fromBackingInt(@intCast(data.lhs))}, w.token(inst));
                try w.earlyReturn(@fromBackingInt(@intCast(data.lhs)), s);
                if (!try w.isTracked(inst)) return &.{};
                const any = try w.o.child(eps, .any, 0);
                const out = try w.a.alloc(Entry, s.len);
                for (s, out) |e, *x| x.* = .{ .path = any, .cell = e.cell, .approx = e.approx };
                return w.norm(out);
            },
            .markup => {
                var values: std.ArrayList(Inst.Index) = .empty;
                try b.markupValues(w.a, @fromBackingInt(@intCast(data.lhs)), &values);
                const avs = try w.evalOperands(values.items, true);
                w.popPending(avs.len);
                const retained = try w.conservativeAV(inst, values.items, avs, &.{}, null, "", false);
                const events = try w.markupTreeEvents(inst, @fromBackingInt(@intCast(data.lhs)), try MarkupValues.init(w.a, values.items, avs));
                return w.unionOf(&.{ try w.shift(retained, .{ .kind = .markup_render, .arg = 0 }), try w.shift(events, .{ .kind = .markup_event, .arg = 0 }) });
            },
            else => return &.{},
        }
    }

    /// Change 9's opaque markup slots. Unknown types/paths keep §6.1's aliases.
    fn markupEvents(w: *Walker, av: AV, ty: ?Var, inst: Inst.Index, depth: u32) Allocator.Error!AV {
        const v = ty orelse return av;
        if (depth >= k_limit) return av;
        switch (w.store.resolvedContent(v)) {
            .structure => |st| switch (st) {
                .app => |app| {
                    const gm = w.o.in.graph.markup;
                    if (gm.type_module.unwrap()) |m| if (gm.type_name.unwrap()) |n| {
                        const id = w.o.in.types.find(w.o.in.graph, .platform, m, n);
                        if (app.type == id and id != .none) return w.proj(av, .{ .kind = .markup_event, .arg = 0 }, null);
                    };
                    const args = w.store.vars(app.args);
                    if (args.len == 1 and app.type == w.o.in.types.well_known.list)
                        return w.markupEvents(try w.proj(av, .{ .kind = .elem, .arg = 0 }, args[0]), args[0], inst, depth + 1);
                    if (args.len == 1 and app.type == w.o.in.types.well_known.maybe) {
                        const e = w.o.in.types.entries[app.type.int()];
                        const b = w.o.in.birs[e.module.int()];
                        for (b.declCtors(b.decls[e.decl.int()])) |c| {
                            if (!std.mem.eql(u8, w.o.in.interner.slice(b.symbol(c.name)), "Just")) continue;
                            for (b.ctors, 0..) |cc, ci| if (cc.name == c.name) {
                                const ctor = try w.o.ctorId(e.module.int(), @intCast(ci));
                                return w.markupEvents(try w.proj(av, .{ .kind = .ctor, .arg = ctor *% 64 }, args[0]), args[0], inst, depth + 1);
                            };
                        }
                    }
                    // Missing Maybe metadata also falls through here: keep
                    // the whole tracked arrival, never infer an empty slot.
                    if (!try w.trackedVar(v)) return &.{};
                    return av;
                },
                .record => |record| {
                    var parts: std.ArrayList(AV) = .empty;
                    for (w.store.fields(record.fields)) |f| try parts.append(w.a, try w.markupEvents(try w.proj(av, .{ .kind = .field, .arg = @backingInt(f.name) }, f.value), f.value, inst, depth + 1));
                    if (try w.trackedVar(record.ext)) try parts.append(w.a, av);
                    return w.unionOf(parts.items);
                },
                .unit, .empty_record => return &.{},
                else => return av,
            },
            else => return av,
        }
    }

    fn viewResultType(w: *Walker, arg: Inst.Index) ?Var {
        if (w.bir.instTag(arg) != .record) return null;
        for (w.bir.extraSlice(Bir.inlineRange(w.bir.instData(arg)), Bir.Field)) |f| {
            if (!std.mem.eql(u8, w.o.in.interner.slice(w.bir.symbol(f.name)), "view")) continue;
            const v = w.instType(f.value) orelse return null;
            return switch (w.store.resolvedContent(v)) {
                .structure => |st| if (st == .func) st.func.result else null,
                else => null,
            };
        }
        return null;
    }

    fn constructorValue(w: *Walker, inst: Inst.Index) Allocator.Error!?AV {
        const sum = (try w.ctorClass(inst)) orelse return null;
        const ci: u32 = @intCast(w.closures.items.len);
        try w.closures.append(w.a, .{ .captures = &.{}, .class = sum, .carried = true, .frame = none });
        return try w.single(.{ .kind = .closure, .a = ci });
    }

    fn markupCallback(w: *Walker, inst: Inst.Index, function: Inst.Index, f: AV, avs: []const AV) Allocator.Error!AV {
        if (try w.ctorClass(function)) |sum| {
            if (sum.params != avs.len) return w.single(.{ .kind = .top, .a = 0 });
            return w.instRes(sum, .{ .inst = inst, .s = sum, .avs = avs, .depth = 1 });
        }
        if (w.fnParamOf(f) orelse try w.slotOf(f)) |j| {
            if (w.frame != 0) return w.single(.{ .kind = .top, .a = 0 });
            w.fn_state.items[j].calls = .many;
            w.cb_args[function.int() - w.decl.inst_start.int()] = try w.unionOf(avs);
            for (avs, 0..) |av, k| if (av.len != 0) {
                try w.supplies.append(w.a, .{ .fun = j, .k = @intCast(k), .path = eps, .av = av, .probe = none, .owned = false, .cond = try w.deepCond(av) });
            };
            return w.single(.{ .kind = .cbres, .a = j, .b = function.int() });
        }
        const classes = try w.classesOf(f);
        if (classes.len == 0) return w.unionOf(&.{ try w.anywhere(try w.unionOf(&.{ f, try w.unionOf(avs) }), inst), try w.single(.{ .kind = .top, .a = 0 }) });
        var out: std.ArrayList(AV) = .empty;
        for (classes) |cls| {
            const sum = (try w.classSummary(cls)) orelse return w.single(.{ .kind = .top, .a = 0 });
            if (sum.params != avs.len) return w.single(.{ .kind = .top, .a = 0 });
            try out.append(w.a, try w.instRes(sum, .{ .inst = inst, .s = sum, .avs = avs, .closure = if (cls == .closure) cls.closure else none, .depth = 1 }));
        }
        return w.unionOf(out.items);
    }

    /// Keep outer captures symbolic while reading a row's nested handlers.
    /// Expanding them to the enclosing declaration's parameters would read
    /// those parameters off in the row's frame, losing them to top.
    fn markupHeld(w: *Walker, av: AV, inst: Inst.Index) Allocator.Error!AV {
        var out: std.ArrayList(AV) = .empty;
        var seen: std.ArrayList(u32) = .empty;
        try w.markupHeldInto(av, &out, &seen);
        return w.anywhere(try w.unionOf(out.items), inst);
    }

    fn markupHeldInto(w: *Walker, av: AV, out: *std.ArrayList(AV), seen: *std.ArrayList(u32)) Allocator.Error!void {
        for (av) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind == .func) continue;
            if (c.kind != .closure) {
                try out.append(w.a, try w.a.dupe(Entry, &.{e}));
                continue;
            }
            if (std.mem.indexOfScalar(u32, seen.items, c.a) != null) continue;
            try seen.append(w.a, c.a);
            for (w.closures.items[c.a].captures) |cap| {
                if (w.frame != 0 and w.local_frame[cap.local] != w.frame) {
                    try out.append(w.a, try w.single(.{ .kind = .env, .a = cap.local, .path = cap.path }));
                } else if (w.local_av[cap.local]) |held| {
                    try w.markupHeldInto(try w.projPath(held, cap.path, null), out, seen);
                } else try out.append(w.a, try w.single(.{ .kind = .top, .a = 0 }));
            }
        }
    }

    const MarkupValues = struct {
        const Value = struct { inst: Inst.Index, av: AV };
        entries: []const Value,

        fn init(a: Allocator, insts: []const Inst.Index, avs: []const AV) Allocator.Error!MarkupValues {
            const entries = try a.alloc(Value, insts.len);
            for (entries, insts, avs) |*entry, inst, av| entry.* = .{ .inst = inst, .av = av };
            std.mem.sort(Value, entries, {}, struct {
                fn less(_: void, x: Value, y: Value) bool {
                    return x.inst.int() < y.inst.int();
                }
            }.less);
            return .{ .entries = entries };
        }

        fn get(v: MarkupValues, inst: Inst.Index) AV {
            var lo: usize = 0;
            var hi = v.entries.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (v.entries[mid].inst.int() < inst.int()) lo = mid + 1 else hi = mid;
            }
            // Both walks cover the same operands; every get in the full
            // markup corpus exercises this invariant under runtime safety.
            std.debug.assert(lo < v.entries.len and v.entries[lo].inst == inst);
            return v.entries[lo].av;
        }
    };

    fn markupTreeEvents(w: *Walker, inst: Inst.Index, root: Bir.ExtraIndex, vals: MarkupValues) Allocator.Error!AV {
        const b = w.bir;
        var parts: std.ArrayList(AV) = .empty;
        switch (b.markupKind(root)) {
            .text => {},
            .hole => {
                const value = b.extraData(root, Bir.MarkupHole).value;
                try parts.append(w.a, try w.markupEvents(vals.get(value), w.instType(value), inst, 0));
            },
            .element => {
                const e = b.extraData(root, Bir.MarkupElement);
                for (b.extraSlice(.{ .start = e.items_start, .end = e.items_end }, Bir.ExtraIndex)) |at| {
                    const item = b.extraData(at, Bir.MarkupItem);
                    const value = item.value.unwrap() orelse continue;
                    var known = false;
                    if (w.m < w.o.in.dispatch.len) for (w.o.in.dispatch[w.m].markup) |fact| {
                        if (fact.node != @backingInt(at)) continue;
                        known = true;
                        if (fact.kind == .event) try parts.append(w.a, try w.markupHeld(vals.get(value), inst));
                    };
                    if (!known) try parts.append(w.a, try w.markupHeld(vals.get(value), inst));
                }
                for (b.extraSlice(.{ .start = e.children_start, .end = e.children_end }, Bir.ExtraIndex)) |node| try parts.append(w.a, try w.markupTreeEvents(inst, node, vals));
            },
            .fragment => {
                const f = b.extraData(root, Bir.MarkupFragment);
                for (b.extraSlice(.{ .start = f.children_start, .end = f.children_end }, Bir.ExtraIndex)) |node| try parts.append(w.a, try w.markupTreeEvents(inst, node, vals));
            },
            .@"for", .show => {
                const form = b.extraData(root, Bir.MarkupForm);
                if (form.fallback.unwrap()) |fallback| try parts.append(w.a, try w.markupEvents(vals.get(fallback), w.instType(fallback), inst, 0));
                if (form.row != Bir.none_extra) {
                    const row = b.extraData(@fromBackingInt(form.row), Bir.MarkupRow);
                    const list = if (form.list.unwrap()) |value| vals.get(value) else &.{};
                    // Unknown Show rows keep their input; For only hands over elements.
                    const element = if (b.markupKind(root) == .@"for") try w.proj(list, .{ .kind = .elem, .arg = 0 }, null) else try w.anywhere(list, inst);
                    var arity: u8 = 1;
                    if (w.m < w.o.in.dispatch.len) for (w.o.in.dispatch[w.m].markup) |fact| {
                        if (fact.node == @backingInt(root)) arity = fact.arity;
                    };
                    const result = try w.markupCallback(inst, row.function, vals.get(row.function), if (arity == 2) &.{ element, &.{} } else &.{element});
                    // The row's result type belongs to this module's store.
                    const ft = w.instType(row.function);
                    const rt: ?Var = if (ft) |v| switch (w.store.resolvedContent(v)) {
                        .structure => |st| if (st == .func) st.func.result else null,
                        else => null,
                    } else null;
                    try parts.append(w.a, try w.markupEvents(result, rt, inst, 0));
                }
            },
            .component => {
                var values: std.ArrayList(Inst.Index) = .empty;
                try b.markupValues(w.a, root, &values);
                for (values.items) |value| try parts.append(w.a, try w.markupHeld(vals.get(value), inst));
                try parts.append(w.a, try w.single(.{ .kind = .top, .a = 0 }));
            },
        }
        return w.anywhere(try w.unionOf(parts.items), inst);
    }

    /// §26.2: `e?` on a `Result` returns `Err x` from the definition it
    /// targets — the frame being walked, since a `?` under a lambda is
    /// refused (`language.md` §6.6) — so `e`'s `Err` payload is part of that
    /// frame's result, exactly. A `Maybe`'s `Nothing` holds nothing.
    fn earlyReturn(w: *Walker, operand: Inst.Index, s: AV) Allocator.Error!void {
        const v = w.instType(operand) orelse return;
        const re = try w.o.resultErr();
        if (re.ty == .none) return;
        const app = switch (w.store.resolvedContent(v)) {
            .structure => |st| switch (st) {
                .app => |x| x,
                else => return,
            },
            else => return,
        };
        if (app.type != re.ty) return;
        const args = w.store.vars(app.args);
        if (args.len == 0) return;
        const step: Step = .{ .kind = .ctor, .arg = re.ctor *% 64 };
        const payload = try w.proj(s, step, args[0]);
        if (payload.len == 0) return;
        try w.frames.items[w.frame].early.appendSlice(w.a, try w.shift(payload, step));
    }

    /// The frame's result: its body's value and what its `?`s return (§26.2).
    fn withEarly(w: *Walker, frame: u32, result: AV) Allocator.Error!AV {
        const early = w.frames.items[frame].early.items;
        if (early.len == 0) return result;
        return w.unionOf(&.{ result, early });
    }

    /// `tracked`, remembered per type variable (§18.11).
    fn trackedVar(w: *Walker, v: Var) Allocator.Error!bool {
        const root, _ = w.store.resolved(v);
        const key = (@as(u64, w.m) << 32) | @backingInt(root);
        if (w.o.tracked_memo.get(key)) |t| return t;
        const t = try w.o.tracked(w.store, v, 0);
        try w.o.tracked_memo.put(w.o.in.gpa, key, t);
        return t;
    }

    fn instTypeOpt(w: *const Walker, inst: Inst.Index) Var.Optional {
        return if (w.instType(inst)) |v| v.toOptional() else .none;
    }

    fn isTracked(w: *Walker, inst: Inst.Index) Allocator.Error!bool {
        const v = w.instType(inst) orelse return true;
        return w.trackedVar(v);
    }

    fn single(w: *Walker, c: Cell) Allocator.Error!AV {
        const id = try w.cell(c);
        return w.a.dupe(Entry, &.{.{ .path = eps, .cell = id }});
    }

    /// A local, or a field path of one; inside a lambda, a local of an
    /// enclosing frame is a capture (§5, §7.3).
    fn evalLocal(w: *Walker, l: u32, path: u32, inst: Inst.Index) Allocator.Error!AV {
        if (l >= w.local_av.len) return &.{};
        const ty = w.instType(inst);
        if (ty) |v| if (!try w.trackedVar(v)) return &.{};
        const bound = w.local_av[l] != null;
        if (w.early[l] == 1) w.early[l] = 2;
        if (bound and w.local_frame[l] == w.frame) return w.projPath(w.local_av[l].?, path, ty);
        // Not bound yet in the declaration's own frame: nothing is known.
        if (w.frame == 0) return &.{};
        // A capture, recorded in every frame between the local's and this
        // one, so an enclosing lambda holds what its inner lambda reads. A
        // local not bound yet (one a local function names above its line)
        // is this frame's capture, looked up when needed.
        var f = w.frame;
        while (f != none) : (f = w.frames.items[f].parent) {
            if (bound and f == w.local_frame[l]) break;
            try w.frames.items[f].captures.append(w.a, .{ .local = l, .path = path });
            if (!bound) break;
        }
        return w.single(.{ .kind = .env, .a = l, .path = path, .ty = if (ty) |v| v.toOptional() else .none });
    }

    fn evalRecordUpdate(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const base_inst: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const fields = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field);
        const base = try w.eval(base_inst);
        try w.pushPending(base, base_inst, false);
        const insts = try w.a.alloc(Inst.Index, fields.len);
        for (fields, insts) |f, *x| x.* = f.value;
        const avs = try w.evalOperands(insts, false);
        w.popPending(avs.len + 1);
        const names = try w.a.alloc(u32, fields.len);
        for (fields, names) |f, *n| n.* = @backingInt(b.symbol(f.name));
        w.point += 1;
        try w.useOperand(base_inst, w.token(inst), names);
        for (insts) |x| try w.useOperand(x, w.token(inst), &.{});
        // The base without the updated fields; a symbolic entry is split
        // into its record type's other fields when the type is closed.
        var out: std.ArrayList(Entry) = .empty;
        const all_fields = w.recordFields(w.instType(base_inst));
        for (base) |e| {
            const k = w.cells.items[e.cell].kind;
            if (e.path == eps and k != .top and k != .site and k != .closure and k != .func) {
                if (all_fields) |fs| {
                    for (fs) |fl| {
                        if (std.mem.indexOfScalar(u32, names, @backingInt(fl.name)) != null) continue;
                        if (!try w.trackedVar(fl.value)) continue;
                        const s: Step = .{ .kind = .field, .arg = @backingInt(fl.name) };
                        if (try w.projCell(e.cell, s, fl.value)) |c| {
                            try out.append(w.a, .{ .path = try w.o.child(eps, .field, s.arg), .cell = c, .approx = e.approx });
                        }
                    }
                    continue;
                }
                try out.append(w.a, e);
                continue;
            }
            if (w.o.firstStep(e.path)) |first| {
                if (first.kind == .field and std.mem.indexOfScalar(u32, names, first.arg) != null) continue;
            }
            try out.append(w.a, e);
        }
        for (fields, avs) |f, av| {
            const shifted = try w.shift(av, .{ .kind = .field, .arg = @backingInt(b.symbol(f.name)) });
            try w.sight(shifted, .{ .pending = "it is stored in a record" }, w.token(inst));
            try out.appendSlice(w.a, shifted);
        }
        return w.norm(out.items);
    }

    /// The fields of a closed record type, or null.
    fn recordFields(w: *Walker, ty: ?Var) ?[]const TypeStore.Field {
        const v = ty orelse return null;
        switch (w.store.resolvedContent(v)) {
            .structure => |s| switch (s) {
                .record => |r| {
                    switch (w.store.resolvedContent(r.ext)) {
                        .structure => |e| if (e == .empty_record) return w.store.fields(r.fields),
                        else => {},
                    }
                    return null;
                },
                else => return null,
            },
            else => return null,
        }
    }

    /// A lambda or local function: its body walked as a frame of its own,
    /// and its class read off it (§16.5).
    fn closure(w: *Walker, params: []const Inst.Index, body: Inst.Index, ci_in: ?u32) Allocator.Error!AV {
        const saved_frame = w.frame;
        const saved_ctx = w.ctx;
        const id: u32 = @intCast(w.frames.items.len);
        try w.frames.append(w.a, .{ .parent = saved_frame, .pending_base = w.pending.items.len });
        const ci: u32 = ci_in orelse blk: {
            try w.closures.append(w.a, .{ .captures = &.{} });
            break :blk @intCast(w.closures.items.len - 1);
        };
        w.closures.items[ci].params = params;
        w.closures.items[ci].frame = id;
        for (params, 0..) |p, k| {
            const at = p.int() -% w.decl.inst_start.int();
            if (at < w.pat_closure.len) w.pat_closure[at] = .{ ci, @intCast(k) };
        }
        w.frame = id;
        const escapes_from = w.escaped.items.len;
        const demands_from = w.demands.items.len;
        for (params) |p| try w.bindParam(p, 1);
        const result = try w.withEarly(id, try w.eval(body));
        try w.consume(&.{body}, w.token(body));
        try w.sight(result, .{ .pending = "it is returned by a function value" }, w.token(body));
        // Captures of locals of this frame only: an inner capture of an
        // outer-outer local was recorded in the frames between.
        var caps: std.ArrayList(Capture) = .empty;
        for (w.frames.items[id].captures.items) |cap| {
            if (cap.local < w.local_frame.len and w.local_frame[cap.local] == id and w.local_av[cap.local] != null) continue;
            try caps.append(w.a, cap);
        }
        w.closures.items[ci].captures = try caps.toOwnedSlice(w.a);
        var env_escapes: std.ArrayList(Capture) = .empty;
        for (w.escaped.items[escapes_from..]) |x| {
            const c = w.cells.items[x.cell];
            if (c.kind != .env or c.a >= w.local_frame.len) continue;
            if (w.local_av[c.a] != null and w.local_frame[c.a] == id) continue;
            try env_escapes.append(w.a, .{ .local = c.a, .path = c.path });
        }
        w.closures.items[ci].env_escapes = try env_escapes.toOwnedSlice(w.a);
        // §18.8: the captures its own body writes make it once.
        var env_writes: std.ArrayList(Capture) = .empty;
        for (w.demands.items[demands_from..]) |rec| {
            if (rec.kind == .probe or rec.kind == .value or rec.frame != id) continue;
            for (rec.cells) |e| {
                const c = w.cells.items[try w.takenBase(e.cell)];
                if (c.kind != .env) continue;
                if (c.a < w.local_frame.len and w.local_av[c.a] != null and w.local_frame[c.a] == id) continue;
                try env_writes.append(w.a, .{ .local = c.a, .path = c.path, .deep = rec.deep });
            }
        }
        w.closures.items[ci].env_writes = try env_writes.toOwnedSlice(w.a);
        const cls = try w.a.create(Summary);
        cls.* = try w.readOffFrame(id, params, result);
        cls.once = w.closures.items[ci].env_writes.len > 0;
        w.closures.items[ci].class = cls;
        w.frame = saved_frame;
        w.ctx = saved_ctx;
        // A lambda's creation demands what it writes of its captures, in the
        // body that creates it; a local function's, at each call, since its
        // captures are read when it runs (§18.8).
        if (!w.closures.items[ci].local) {
            w.point += 1;
            const value = try w.single(.{ .kind = .closure, .a = ci });
            try w.useCaptures(value, w.token(body));
            if (cls.once) try w.onceCreation(ci, w.token(body));
        }
        return w.single(.{ .kind = .closure, .a = ci });
    }

    /// §18.8: the creation of a once closure (or a call of a once local
    /// function) demands the captures it writes, in the current body; the
    /// closure is the one holder allowed to stay live.
    fn onceCreation(w: *Walker, ci: u32, tok: u32) Allocator.Error!void {
        for (w.closures.items[ci].env_writes) |cap| {
            const av = if (cap.local < w.local_frame.len and w.local_frame[cap.local] == w.frame)
                (if (w.local_av[cap.local]) |held| try w.projPath(held, cap.path, null) else continue)
            else
                try w.single(.{ .kind = .env, .a = cap.local, .path = cap.path });
            const p = try w.onceDemandDeep(.creation, tok, if (cap.deep) try w.flat(av) else av, .{ .local = cap.local, .path = cap.path }, ci, cap.deep);
            try w.closures.items[ci].once_probes.append(w.a, p);
        }
    }

    /// §18.8: a call of a once closure is a demand on its own cell, so a
    /// second call — or a holder read after this one — fails Dead.
    fn onceCall(w: *Walker, ci: u32, f: AV, tok: u32) Allocator.Error!void {
        const cl = &w.closures.items[ci];
        // Its recursion is a second call while the first runs.
        if (w.inFrameOf(cl.frame)) {
            if (cl.once_bad == null) cl.once_bad = "it calls itself, a second call while the first runs";
            return;
        }
        var cells: std.ArrayList(Entry) = .empty;
        for (f) |e| if (e.path == eps) try cells.append(w.a, e);
        if (cells.items.len == 0) try cells.append(w.a, .{ .path = eps, .cell = try w.cell(.{ .kind = .closure, .a = ci }) });
        const p = try w.onceDemand(.probe, tok, cells.items, null, ci);
        try w.closures.items[ci].call_probes.append(w.a, p);
        if (w.closures.items[ci].local) try w.onceCreation(ci, tok);
    }

    /// Whether the walk is inside frame `f` or a frame it encloses.
    fn inFrameOf(w: *const Walker, f: u32) bool {
        var at = w.frame;
        while (at != none) : (at = w.frames.items[at].parent) {
            if (at == f) return true;
        }
        return false;
    }

    fn evalLet(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const items = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.lhs))), Inst.Index);
        // Local functions first: their closures exist from the block's
        // entry (thesis §3.6, *Local functions*), and their captures are
        // looked up when needed, so a later local is found. One named
        // before its class exists — by itself or by a sibling walked first
        // — was called out of the walk's sight (§16.5).
        var group: std.ArrayList([2]u32) = .empty;
        for (items) |item| {
            if (b.instTag(item) != .let_def) continue;
            const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
            if (ld.params_start == ld.params_end) continue;
            try w.closures.append(w.a, .{ .captures = &.{}, .local = true });
            const ci: u32 = @intCast(w.closures.items.len - 1);
            try group.append(w.a, .{ ld.local, ci });
            if (ld.local < w.early.len) w.early[ld.local] = 1;
        }
        if (group.items.len > 0) try w.walkGroup(items, group.items);
        for (group.items) |g| if (g[0] < w.early.len) {
            w.early[g[0]] = 0;
        };
        for (items) |item| {
            const idata = b.instData(item);
            switch (b.instTag(item)) {
                .let_def => {
                    const ld = b.extraData(@fromBackingInt(@intCast(idata.lhs)), Bir.LetDef);
                    if (ld.params_start != ld.params_end) continue;
                    const value: Inst.Index = @fromBackingInt(@intCast(idata.rhs));
                    const av = try w.eval(value);
                    try w.consume(&.{value}, w.token(item));
                    w.bindLocal(ld.local, av);
                },
                .let_pattern => {
                    const value: Inst.Index = @fromBackingInt(@intCast(idata.rhs));
                    const av = try w.eval(value);
                    try w.consume(&.{value}, w.token(item));
                    try w.bindPattern(@fromBackingInt(@intCast(idata.lhs)), av);
                },
                .let_stmt => {
                    const value: Inst.Index = @fromBackingInt(@intCast(idata.rhs));
                    _ = try w.eval(value);
                    try w.consume(&.{value}, w.token(item));
                },
                else => {},
            }
        }
        const body: Inst.Index = @fromBackingInt(@intCast(data.rhs));
        const result = try w.eval(body);
        try w.consume(&.{body}, w.token(body));
        return result;
    }

    /// §18.7: a block's local functions are one group. Their closures exist
    /// from the block's entry, each with the bottom class; when a member
    /// names a member, the group is solved like a recursive top-level group
    /// (§16.6): each round walks every member and joins what it reads off,
    /// and a round's demands and uses are discarded before the next, so the
    /// walk that validates the classes is the one that stays.
    fn walkGroup(w: *Walker, items: []const Inst.Index, group: []const [2]u32) Allocator.Error!void {
        const b = w.bir;
        var gi0: usize = 0;
        for (items) |item| {
            if (b.instTag(item) != .let_def) continue;
            const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
            if (ld.params_start == ld.params_end) continue;
            const g = group[gi0];
            gi0 += 1;
            const bottom = try w.a.create(Summary);
            bottom.* = .{ .params = @intCast(b.extraSlice(.{ .start = ld.params_start, .end = ld.params_end }, Inst.Index).len) };
            w.closures.items[g[1]].class = bottom;
            w.bindLocal(g[0], try w.single(.{ .kind = .closure, .a = g[1] }));
        }
        const snap = try w.snapshot();
        const assume = try w.a.alloc(*const Summary, group.len);
        for (group, assume) |g, *x| x.* = w.closures.items[g[1]].class.?;
        var round: u32 = 0;
        while (true) : (round += 1) {
            var gi: usize = 0;
            for (items) |item| {
                if (b.instTag(item) != .let_def) continue;
                const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
                if (ld.params_start == ld.params_end) continue;
                const params = b.extraSlice(.{ .start = ld.params_start, .end = ld.params_end }, Inst.Index);
                _ = try w.closure(params, @fromBackingInt(@intCast(b.instData(item).rhs)), group[gi][1]);
                gi += 1;
            }
            var named = false;
            for (group) |g| if (g[0] < w.early.len and w.early[g[0]] == 2) {
                named = true;
            };
            if (!named) return;
            var changed = false;
            for (group, assume) |g, *x| {
                const joined = try w.o.join(x.*.*, w.closures.items[g[1]].class.?.*);
                if (!summaryEql(joined, x.*.*)) changed = true;
                const p = try w.a.create(Summary);
                p.* = joined;
                x.* = p;
            }
            if (!changed) return;
            try w.restore(snap);
            for (group, assume) |g, *x| {
                if (round + 1 >= round_cap) {
                    const p = try w.a.create(Summary);
                    p.* = try w.o.pessimistic(x.*.*, .rounds);
                    x.* = p;
                }
                w.closures.items[g[1]].class = x.*;
                if (g[0] < w.early.len) w.early[g[0]] = 1;
            }
            if (round + 1 >= round_cap) {
                // The backstop: one walk against the pessimistic classes,
                // which stay.
                gi = 0;
                for (items) |item| {
                    if (b.instTag(item) != .let_def) continue;
                    const ld = b.extraData(@fromBackingInt(@intCast(b.instData(item).lhs)), Bir.LetDef);
                    if (ld.params_start == ld.params_end) continue;
                    const params = b.extraSlice(.{ .start = ld.params_start, .end = ld.params_end }, Inst.Index);
                    _ = try w.closure(params, @fromBackingInt(@intCast(b.instData(item).rhs)), group[gi][1]);
                    gi += 1;
                }
                for (group, assume) |g, x| w.closures.items[g[1]].class = x;
                return;
            }
        }
    }

    const Snapshot = struct {
        demands: usize,
        uses: usize,
        escaped: usize,
        supplies: usize,
        probes: usize,
        reqs: usize,
        env_calls: usize,
        frames: usize,
        closures: usize,
        conds: usize,
        captures: []const usize,
        consumed: []const usize,
        once_probes: []const [2]usize,
        once_bad: []const ?[]const u8,
        fn_state: []const FnState,
        unseen: std.AutoHashMapUnmanaged(u64, void),
        cell_cond: []const u32,
        cell_spine: []const u32,
        esc_index: std.AutoHashMapUnmanaged([4]u32, EscAt),
        esc_heads: std.AutoHashMapUnmanaged([4]u32, u32),
        local_av: []const ?AV,
        local_frame: []const u32,
        local_ctx: []const u32,
    };

    fn snapshot(w: *Walker) Allocator.Error!Snapshot {
        const n = w.closures.items.len;
        const consumed = try w.a.alloc(usize, n);
        const once_probes = try w.a.alloc([2]usize, n);
        const once_bad = try w.a.alloc(?[]const u8, n);
        for (w.closures.items, consumed, once_probes, once_bad) |c, *x, *y, *z| {
            x.* = c.consumed.items.len;
            y.* = .{ c.once_probes.items.len, c.call_probes.items.len };
            z.* = c.once_bad;
        }
        const captures = try w.a.alloc(usize, w.frames.items.len);
        for (w.frames.items, captures) |f, *x| x.* = f.captures.items.len;
        return .{
            .demands = w.demands.items.len,
            .uses = w.uses.items.len,
            .escaped = w.escaped.items.len,
            .supplies = w.supplies.items.len,
            .probes = w.probe_ok.items.len,
            .reqs = w.reqs.items.len,
            .env_calls = w.env_calls.items.len,
            .frames = w.frames.items.len,
            .closures = n,
            .conds = w.conds.items.len,
            .captures = captures,
            .consumed = consumed,
            .once_probes = once_probes,
            .once_bad = once_bad,
            .fn_state = try w.a.dupe(FnState, w.fn_state.items),
            .unseen = try w.unseen_funcs.clone(w.a),
            .cell_cond = try w.a.dupe(u32, w.cell_cond.items),
            .cell_spine = try w.a.dupe(u32, w.cell_spine.items),
            .esc_index = try w.esc_index.clone(w.a),
            .esc_heads = try w.esc_heads.clone(w.a),
            .local_av = try w.a.dupe(?AV, w.local_av),
            .local_frame = try w.a.dupe(u32, w.local_frame),
            .local_ctx = try w.a.dupe(u32, w.local_ctx),
        };
    }

    fn restore(w: *Walker, s: Snapshot) Allocator.Error!void {
        w.demands.shrinkRetainingCapacity(s.demands);
        w.uses.shrinkRetainingCapacity(s.uses);
        w.escaped.shrinkRetainingCapacity(s.escaped);
        w.supplies.shrinkRetainingCapacity(s.supplies);
        w.probe_ok.shrinkRetainingCapacity(s.probes);
        w.probe_approx.shrinkRetainingCapacity(s.probes);
        w.probe_info.shrinkRetainingCapacity(s.probes);
        w.reqs.shrinkRetainingCapacity(s.reqs);
        w.env_calls.shrinkRetainingCapacity(s.env_calls);
        w.frames.shrinkRetainingCapacity(s.frames);
        w.closures.shrinkRetainingCapacity(s.closures);
        w.conds.shrinkRetainingCapacity(s.conds);
        for (w.frames.items, s.captures) |*f, n| f.captures.shrinkRetainingCapacity(n);
        for (w.closures.items, s.consumed, s.once_probes, s.once_bad) |*c, x, y, z| {
            c.consumed.shrinkRetainingCapacity(x);
            c.once_probes.shrinkRetainingCapacity(y[0]);
            c.call_probes.shrinkRetainingCapacity(y[1]);
            c.once_bad = z;
        }
        w.fn_state.shrinkRetainingCapacity(s.fn_state.len);
        w.slot_keys.shrinkRetainingCapacity(s.fn_state.len - w.params.len);
        @memcpy(w.fn_state.items, s.fn_state);
        w.unseen_funcs = try s.unseen.clone(w.a);
        @memcpy(w.cell_cond.items[0..s.cell_cond.len], s.cell_cond);
        @memset(w.cell_cond.items[s.cell_cond.len..], none);
        @memcpy(w.cell_spine.items[0..s.cell_spine.len], s.cell_spine);
        @memset(w.cell_spine.items[s.cell_spine.len..], none);
        w.esc_index = try s.esc_index.clone(w.a);
        w.esc_heads = try s.esc_heads.clone(w.a);
        @memcpy(w.local_av, s.local_av);
        @memcpy(w.local_frame, s.local_frame);
        @memcpy(w.local_ctx, s.local_ctx);
    }

    fn evalCase(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const scrutinee: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const s = try w.eval(scrutinee);
        try w.consume(&.{scrutinee}, w.token(inst));
        const branches = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index);
        const case_id = w.cases;
        w.cases += 1;
        const saved = w.ctx;
        var results: std.ArrayList(AV) = .empty;
        for (branches, 0..) |br, arm| {
            const node: u32 = @intCast(w.ctx_nodes.items.len);
            try w.ctx_nodes.append(w.a, .{ .parent = saved, .case_id = case_id, .arm = @intCast(arm), .depth = w.ctx_nodes.items[saved].depth + 1 });
            w.ctx = node;
            try w.bindPattern(@fromBackingInt(@intCast(b.instData(br).lhs)), s);
            const body: Inst.Index = @fromBackingInt(@intCast(b.instData(br).rhs));
            try results.append(w.a, try w.eval(body));
            try w.consume(&.{body}, w.token(body));
        }
        w.ctx = saved;
        return w.unionOf(results.items);
    }

    // ---- calls (§6, §16.4) -----------------------------------------------

    fn evalCall(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const callee: Inst.Index = @fromBackingInt(@intCast(data.lhs));
        const args = w.callArgs(inst);
        if (w.isSpreadCall(inst)) return w.construction(inst);
        if (w.isListAppend(inst)) return w.appendChain(inst);
        switch (b.instTag(callee)) {
            .ctor, .ext_ctor => {
                const c = try w.ctorOf(callee);
                const avs = try w.evalOperands(args, false);
                w.popPending(avs.len);
                try w.consume(args, w.token(inst));
                var parts = try w.a.alloc(AV, avs.len);
                for (avs, 0..) |av, i| parts[i] = try w.shift(av, .{ .kind = .ctor, .arg = c *% 64 +% @as(u32, @intCast(i)) });
                try w.storedBeside(parts);
                const out = try w.unionOf(parts);
                try w.sight(out, .{ .pending = "it is stored in a constructor" }, w.token(inst));
                return out;
            },
            else => {},
        }
        if (w.valueTarget(callee)) |t| {
            try w.evidenceSight(callee);
            try w.evidenceSight(inst);
            if (args.len == 1) if (w.entryRow(t)) |row| return w.entryCall(inst, t, args[0], row);
            return w.callTarget(inst, t, args);
        }
        // A function value: its classes, when the walk knows where it came
        // from (§16.5); else a conservative call that reads its captures.
        const f = try w.eval(callee);
        try w.pushPending(f, callee, true);
        defer w.popPending(1);
        // A call of a function parameter of the declaration (§16.4 item 4).
        if (w.fnParamOf(f)) |j| {
            if (w.frame == 0) return w.callbackCall(inst, j, args, callee);
            // Inside a lambda: a call made wherever the lambda runs (§18.9).
            if (w.frameClosure(w.frame)) |ci| return w.envCall(inst, ci, j, args, callee);
            w.fn_state.items[j].seen = false;
        }
        // A function stored at a path of a parameter (§24.9): a slot.
        if (try w.slotOf(f)) |j| return w.callbackCall(inst, j, args, callee);
        const classes = try w.classesOf(f);
        if (classes.len == 1) {
            switch (classes[0]) {
                .closure => |ci| if (w.closures.items[ci].class) |cls| {
                    try w.closures.items[ci].consumed.append(w.a, .{ .kind = .local });
                    try w.escapeCaptures(ci, w.point);
                    const out = try w.applySummary(inst, .{ .sum = cls, .name = "<lambda>", .op = "call <lambda>", .closure = ci }, args, f, callee);
                    if (cls.once) try w.onceCall(ci, f, w.token(inst));
                    return out;
                },
                .func => |t| if (try w.o.ensureSummary(t.m, t.d)) |s| {
                    return w.applySummary(inst, .{ .sum = s, .name = try w.qualified(t), .op = try w.callOp(t), .merge_fresh = w.o.isComputing(t.m, t.d) }, args, f, callee);
                },
                // §23.2: a send gives up every cell of its payload.
                .send => return w.applySummary(inst, .{ .sum = &send_class, .name = "send", .op = "send" }, args, f, callee),
            }
        }
        try w.sight(f, .{ .pending = "it is called where the checker does not know which function runs" }, w.token(inst));
        return w.conservative(inst, args, f, callee, "", false);
    }

    /// A top-level value's cells, from its definition's summary: each cell
    /// it makes is shared at the path it makes it at (thesis §3.10).
    fn sharedOf(w: *Walker, s: *const Summary, t: Target, inst: Inst.Index) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        for (s.res) |r| {
            // A lambda the value holds (§24.9), when it captured nothing: a
            // capture the definition made would be a shared cell, which a
            // carried binding cannot say. Dropped otherwise: a call of the
            // value then finds no class and is §6.1's, as it was before.
            if (r.prov.kind == .klass) {
                if (r.prov.a < s.klasses.len and s.klasses[r.prov.a].binds.len == 0 and s.klasses[r.prov.a].cb_js.len == 0) {
                    const av = try w.carry(r.prov, .{ .inst = inst, .s = s, .avs = &.{}, .depth = 0 });
                    try out.appendSlice(w.a, try w.under(av, r.path));
                }
                continue;
            }
            const c: Cell = switch (r.prov.kind) {
                .fresh, .esc => .{ .kind = .shared, .a = t.m, .b = t.d, .path = r.path, .made = true, .ty = if (r.path == eps) w.instTypeOpt(inst) else .none },
                .shared => .{ .kind = .shared, .a = r.prov.a, .b = r.prov.b, .path = r.prov.path },
                else => .{ .kind = .top, .a = if (s.limit != .none or r.prov.a == 1) 1 else 0 },
            };
            try out.append(w.a, .{ .path = r.path, .cell = try w.cell(c), .approx = if (r.approx) inst.int() + 1 else 0 });
        }
        return w.norm(out.items);
    }

    fn callOp(w: *Walker, t: Target) Allocator.Error![]const u8 {
        if (w.writerName(t)) |n| return if (w.mode == .report) std.fmt.allocPrint(w.o.out.allocator(), "List.{s}", .{n}) else "List.";
        if (w.mode != .report) return "call";
        return std.fmt.allocPrint(w.o.out.allocator(), "call {s}", .{try w.qualified(t)});
    }

    /// A call of a top-level value (§16.4), or §6.1 when it has no summary.
    fn callTarget(w: *Walker, inst: Inst.Index, t: Target, args: []const Inst.Index) Allocator.Error!AV {
        // A top-level value whose value is a function has no parameters to
        // apply a summary to: its call is §6.1's.
        if (w.o.in.birs[t.m].decls[t.d].kind == .vocab_markup) {
            const name = w.targetName(t);
            if (std.mem.eql(u8, name, "text") and args.len == 1) {
                const retained = try w.conservative(inst, args, &.{}, null, "", false);
                return w.shift(retained, .{ .kind = .markup_render, .arg = 0 });
            }
            if (std.mem.eql(u8, name, "map") and args.len == 2) {
                const avs = try w.evalOperands(args, true);
                w.popPending(avs.len);
                const retained = try w.conservativeAV(inst, args, avs, &.{}, null, "", false);
                const child_events = try w.markupEvents(avs[0], w.instType(args[0]), inst, 0);
                const mapper = avs[1];
                const mapped = try w.markupCallback(inst, args[1], mapper, &.{child_events});
                const events = try w.anywhere(try w.unionOf(&.{ child_events, mapped, try w.markupHeld(mapper, inst) }), inst);
                return w.unionOf(&.{ try w.shift(retained, .{ .kind = .markup_render, .arg = 0 }), try w.shift(events, .{ .kind = .markup_event, .arg = 0 }) });
            }
        }
        const has_params = w.o.in.birs[t.m].decls[t.d].params > 0;
        // `Js.maySuspend f` reads the static bit the checker inferred for
        // `f` and nothing of its value: no use, and `f` stays in sight
        // (§23.3), so `Cmd.perform`'s body keeps its send position.
        if (w.isCore(t, "Js") and std.mem.eql(u8, w.targetName(t), "maySuspend")) {
            const avs = try w.evalOperands(args, false);
            w.popPending(avs.len);
            return &.{};
        }
        if (if (has_params) try w.o.ensureSummary(t.m, t.d) else null) |s| {
            const saved = w.maybe_join;
            defer w.maybe_join = saved;
            if (try w.isMaybeJoin(t, args)) w.maybe_join = try w.openMaybeJoin(inst);
            return w.applySummary(inst, .{ .sum = s, .name = try w.qualified(t), .op = try w.callOp(t), .merge_fresh = w.o.isComputing(t.m, t.d) }, args, &.{}, null);
        }
        if (w.escapes(t)) return w.escapeCall(inst, args, try w.qualified(t));
        return w.conservative(inst, args, &.{}, null, try w.qualified(t), w.o.in.birs[t.m].decls[t.d].kind == .foreign_value);
    }

    /// §7.2 as amended for slice 3f: `Maybe.withDefault (Maybe.map m f) d`,
    /// both core's, where `m` and `d` are variable paths and `f` a lambda or
    /// a top-level value. `Maybe.map` calls `f` exactly when `m` is `Just`,
    /// and `withDefault` returns `d` exactly when `map` answered `Nothing`,
    /// so what `f`'s call writes and what `d` is read for are on two paths
    /// no run takes both of. `m`, `f` and `d` evaluate nothing but reads, so
    /// the arms hold only the call of `f` and the read of `d`.
    ///
    /// §26.4: `Result.withDefault (Result.map m f) d` is the same shape —
    /// `Result.map` calls `f` exactly when `m` is `Ok`, and `withDefault`
    /// answers `d` exactly when `map` answered `Err`. Not `andThen`, of
    /// either module: its `f` may answer `Nothing` or `Err`, and then `d` is
    /// read after `f` ran.
    fn isMaybeJoin(w: *Walker, t: Target, args: []const Inst.Index) Allocator.Error!bool {
        if (args.len != 2 or !std.mem.eql(u8, w.targetName(t), "withDefault")) return false;
        const module: []const u8 = if (w.isCore(t, "Maybe")) "Maybe" else if (w.isCore(t, "Result")) "Result" else return false;
        if ((try w.refPath(args[1])) == null) return false;
        const inner = args[0];
        if (w.bir.instTag(inner) != .call) return false;
        const it = w.valueTarget(@fromBackingInt(@intCast(w.bir.instData(inner).lhs))) orelse return false;
        if (!w.isCore(it, module) or !std.mem.eql(u8, w.targetName(it), "map")) return false;
        const ia = w.callArgs(inner);
        if (ia.len != 2 or (try w.refPath(ia[0])) == null) return false;
        return switch (w.bir.instTag(ia[1])) {
            .lambda, .top, .ext_value => true,
            else => false,
        };
    }

    /// The two arms of a `MaybeJoin`, as a `case` of its own (§7.2).
    fn openMaybeJoin(w: *Walker, inst: Inst.Index) Allocator.Error!MaybeJoin {
        const case_id = w.cases;
        w.cases += 1;
        const depth = w.ctx_nodes.items[w.ctx].depth + 1;
        const just: u32 = @intCast(w.ctx_nodes.items.len);
        try w.ctx_nodes.append(w.a, .{ .parent = w.ctx, .case_id = case_id, .arm = 0, .depth = depth });
        try w.ctx_nodes.append(w.a, .{ .parent = w.ctx, .case_id = case_id, .arm = 1, .depth = depth });
        return .{ .call = inst, .just = just, .nothing = just + 1 };
    }

    /// The branch context argument `i` of the call at `inst` is walked in.
    fn joinArm(w: *const Walker, inst: Inst.Index, i: usize) ?u32 {
        const j = w.maybe_join orelse return null;
        if (j.call != inst) return null;
        return if (i == 0) j.just else j.nothing;
    }

    // ---- the entry protocol (§20) -----------------------------------------

    /// The entry row of a program constructor (§20.2), or null.
    fn entryRow(w: *const Walker, t: Target) ?EntryRow {
        const names = w.o.in.platform_names;
        if (t.m >= names.len) return null;
        const pkg = names[t.m];
        const module = w.o.in.module_names[t.m];
        const name = w.targetName(t);
        // §20.2 as amended (§28.2): the direct row is the in-place
        // property's, whatever the package is called.
        const in_place = t.m < w.o.in.in_place.len and w.o.in.in_place[t.m];
        if (std.mem.eql(u8, module, "Tea") and eqlAny(name, &.{ "sandbox", "element", "document", "application" })) {
            if (in_place) return .direct;
            if (std.mem.eql(u8, pkg, "browser-tea")) return .template;
        }
        if (!in_place and std.mem.eql(u8, pkg, "browser") and std.mem.eql(u8, module, "Browser") and std.mem.eql(u8, name, "program")) return .template;
        return null;
    }

    /// A record value's field, by name.
    fn fieldOf(w: *Walker, av: AV, name: []const u8) Allocator.Error!AV {
        const sym = w.o.in.interner.find(name) orelse return &.{};
        return w.proj(av, .{ .kind = .field, .arg = @backingInt(sym) }, null);
    }

    /// One of a record's functions, with its class summaries.
    const EntryFn = struct {
        classes: []const Class = &.{},
        sums: []const *const Summary = &.{},
    };

    fn entryFn(w: *Walker, av: AV) Allocator.Error!?EntryFn {
        if (av.len == 0) return .{};
        const classes = try w.classesOf(av);
        if (classes.len == 0) return null;
        const sums = try w.a.alloc(*const Summary, classes.len);
        for (classes, sums) |cls, *s| s.* = (try w.classSummary(cls)) orelse return null;
        // The runtime calls it: a lambda's demands on its own parameters are
        // the entry's (§20.6), and a once closure runs at every message.
        for (classes, sums) |cls, s| if (cls == .closure) {
            const cl = &w.closures.items[cls.closure];
            try cl.consumed.append(w.a, .{ .kind = .local });
            if (s.once and cl.once_bad == null) cl.once_bad = "the platform's runtime calls it at every message";
        };
        return .{ .classes = classes, .sums = sums };
    }

    const entry_init_ns: u32 = 100_000;
    const entry_view_ns: u32 = 200_000;
    const entry_subs_ns: u32 = 300_000;

    /// `f`'s result for these arguments: each class's `res`, instantiated
    /// at the constructor's call (§16.4 item 6).
    fn entryRes(w: *Walker, inst: Inst.Index, f: EntryFn, avs: []const AV, ns: u32) Allocator.Error!AV {
        return w.entryResWith(inst, f, avs, ns, true);
    }

    fn entryResWith(w: *Walker, inst: Inst.Index, f: EntryFn, avs: []const AV, ns: u32, conds: bool) Allocator.Error!AV {
        return w.entryResMode(inst, f, avs, ns, conds, true);
    }

    fn entryResMode(w: *Walker, inst: Inst.Index, f: EntryFn, avs: []const AV, ns: u32, conds: bool, effects: bool) Allocator.Error!AV {
        var parts: std.ArrayList(AV) = .empty;
        for (f.classes, f.sums) |cls, s| {
            const ci: u32 = if (cls == .closure) cls.closure else none;
            try parts.append(w.a, try w.instRes(s, .{ .inst = inst, .s = s, .avs = avs, .closure = ci, .depth = 0, .fresh_ns = ns, .conds = conds, .effects = effects }));
        }
        return w.unionOf(parts.items);
    }

    fn entryConditions(w: *Walker, inst: Inst.Index, update: EntryFn, payload: AV, initial: AV, model: AV) Allocator.Error!void {
        var fresh: std.ArrayList(u32) = .empty;
        const made_initially = try w.expand(initial);
        for (model) |e| {
            const c = w.cells.items[e.cell];
            // The entry namespaces update below 100000, init from 100000,
            // view from 200000 and subscriptions from 300000 (§20.4).
            if (c.kind != .result or c.a != inst.int() or c.b == 0 or c.b >= entry_init_ns or try w.isEscaped(e.cell)) continue;
            // A callback's cells may use the lower namespace too. Anything
            // present at init keeps its established condition, never a guess.
            const initial_cell = for (made_initially) |i| {
                if ((try w.covers(i.cell, e.cell)) != null) break true;
            } else false;
            if (initial_cell) continue;
            if (std.mem.indexOfScalar(u32, fresh.items, e.cell) != null) continue;
            try fresh.append(w.a, e.cell);
            w.cell_cond.items[e.cell] = cond_yes;
        }
        if (fresh.items.len == 0) return;
        for (0..round_cap) |_| {
            const before = try w.a.dupe(u32, w.cell_cond.items);
            const demands_before = w.demands.items.len;
            const uses_before = w.uses.items.len;
            const escapes_before = w.escaped.items.len;
            _ = try w.entryResMode(inst, update, &.{ payload, model }, 0, true, false);
            if (std.debug.runtime_safety) {
                std.debug.assert(w.demands.items.len == demands_before);
                std.debug.assert(w.uses.items.len == uses_before);
                std.debug.assert(w.escaped.items.len == escapes_before);
            }
            if (std.mem.eql(u32, before, w.cell_cond.items)) return;
        }
        // A backstop loses the invariant; never use an unfinished proof.
        for (fresh.items) |c| try w.lowerCond(c, cond_lost);
    }

    /// Every cell of `av`, closures expanded, at `⋆`: what a value built
    /// from them may hold anywhere. A closure's own cell is no list; what it
    /// captured is expanded into the result, so a message holding a handler
    /// that captured a model list still names that list.
    fn anywhere(w: *Walker, av: AV, inst: Inst.Index) Allocator.Error!AV {
        const any = try w.o.child(eps, .any, 0);
        var out: std.ArrayList(Entry) = .empty;
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = inst.int() + 1 });
        }
        return w.norm(out.items);
    }

    /// A call of a program constructor with an entry row (§20.2–§20.6): the
    /// model at entry as the fixpoint of `init` and `update`, what the
    /// runtime's calls escape, and a demand for each path `update` writes.
    fn entryCall(w: *Walker, inst: Inst.Index, t: Target, arg: Inst.Index, row: EntryRow) Allocator.Error!AV {
        const saved = w.entry_arg;
        w.entry_arg = arg.int();
        const app = try w.eval(arg);
        w.entry_arg = saved;
        w.point += 1;
        const tok = w.token(inst);
        try w.useOperand(arg, tok, &.{});
        try w.useTemporaries(&.{arg}, &.{app}, tok);
        const name = w.targetName(t);
        // The model is `init`'s whole value, or its first component (§20.3).
        const whole = std.mem.eql(u8, name, "sandbox") or std.mem.eql(u8, name, "program");
        const tuple0: Step = .{ .kind = .tuple, .arg = 0 };
        const tuple1: Step = .{ .kind = .tuple, .arg = 1 };
        const upd = (try w.entryFn(try w.fieldOf(app, "update"))) orelse {
            // The runtime calls a function the walk cannot place.
            try w.sight(app, .{ .pending = "it is handed to a program whose update the checker cannot place" }, tok);
            return w.entryResult(inst);
        };
        const view = (try w.entryFn(try w.fieldOf(app, "view"))) orelse EntryFn{};
        const subs = (try w.entryFn(try w.fieldOf(app, "subscriptions"))) orelse EntryFn{};
        // `init` is a function the runtime calls once per mount (§22.2): of
        // `⊤`, which holds no cell, or for an application of the address,
        // which crosses, and the navigation key, a foreign type (§20.3).
        // A function the walk cannot place makes a model it cannot know.
        const init_args: []const AV = if (std.mem.eql(u8, name, "application"))
            &.{ &.{}, try w.single(.{ .kind = .top, .a = 0 }) }
        else
            &.{&.{}};
        const init_av = if (try w.entryFn(try w.fieldOf(app, "init"))) |f|
            try w.entryRes(inst, f, init_args, entry_init_ns)
        else
            try w.single(.{ .kind = .top, .a = 0 });
        const m0 = if (whole) init_av else try w.proj(init_av, tuple0, null);
        // A message type that holds no cell brings none (§20.5).
        const msg_tracked = try w.messageTracked(arg);
        const payload: AV = if (msg_tracked) try w.single(.{ .kind = .payload, .a = inst.int() }) else &.{};
        // The fixpoint (§20.4): update's fresh cells are one per number in
        // every round, so it settles; 8 rounds is a backstop. Its rounds
        // compute cells only; the round that settles lowers their conditions.
        // §23.6: what a send gave up is owned; a view event's message is
        // not, and may hold the lists the view's messages carry. They are not
        // carried round the loop: they reach the model only where an arm
        // stores a payload, which the cell `msg` marks, so a demand that
        // reaches `msg` while the view's messages may hold a list is the
        // view-event rule's (P6). So the view is read once, on the settled
        // model.
        var model = m0;
        var res: AV = &.{};
        var round: u32 = 0;
        while (true) : (round += 1) {
            res = try w.entryResWith(inst, upd, &.{ payload, model }, 0, false);
            const half = if (whole) res else try w.proj(res, tuple0, null);
            // The union is sorted and deduplicated, and contains `model`: the
            // same length is the same set, so it has settled.
            const next = try w.unionOf(&.{ model, half });
            if (next.len == model.len) break;
            model = next;
            if (round >= 8) {
                model = try w.unionOf(&.{ model, try w.single(.{ .kind = .top, .a = 0 }) });
                break;
            }
        }
        // Fresh update results participate in the model's inductive
        // exclusivity invariant. Init's conditions are never reseeded.
        try w.entryConditions(inst, upd, payload, m0, model);
        const view_msgs: AV = if (msg_tracked) try w.viewMessages(inst, view, model, true, w.viewResultType(arg)) else &.{};
        const msg = try w.unionOf(&.{ payload, view_msgs });
        res = try w.entryRes(inst, upd, &.{ msg, model }, 0);
        // (a) What every call the runtime makes escapes.
        for (upd.sums) |s| for (s.uses) |u| {
            if (u.param == 1) try w.entryEscape(inst, try w.projPath(model, u.path, null), u.bits);
        };
        if (!whole) {
            try w.escape(try w.proj(res, tuple1, null), w.point);
            try w.escape(try w.proj(init_av, tuple1, null), w.point);
        }
        for ([_]EntryFn{ view, subs }) |f| for (f.sums) |s| for (s.uses) |u| {
            if (u.param == 0) try w.entryEscape(inst, try w.projPath(model, u.path, null), u.bits);
        };
        try w.escape(try w.entryRes(inst, subs, &.{model}, entry_subs_ns), w.point);
        w.point += 1;
        // (b) The demands.
        const arena = w.o.out.allocator();
        const op = if (w.mode == .report) try std.fmt.allocPrint(arena, "entry {s}", .{try w.entryName(upd, "update")}) else "entry";
        // One demand per path written, its derivation and exclusivity the
        // worst any of update's classes gives (an exact write beats an
        // approximate one, a failed `xreq` beats a held one).
        const Written = struct { param: u32, path: u32, origin: Origin, xfail: ?Rely, deep: bool };
        var written: std.ArrayList(Written) = .empty;
        for (upd.classes, upd.sums) |cls, s| for (s.uses) |u| {
            if (u.bits & bit_w == 0 or u.param > 1) continue;
            const origin: Origin = if (s.limit != .none) .limit else if (u.bits & bit_x == 0) .approx else .exact;
            // update's xreq on the model, or on its message (§23.6), at
            // this path (§18.4 item 3).
            var xfail: ?Rely = null;
            {
                const ci: u32 = if (cls == .closure) cls.closure else none;
                for (s.xreq) |x| {
                    const p = xreqParam(x) orelse continue;
                    if (p != u.param) continue;
                    const k = try w.instXSum(.{ .atoms = &.{x} }, .{ .inst = inst, .s = s, .avs = &.{ msg, model }, .closure = ci, .depth = 0 });
                    const r = try w.rely(k, w.frame);
                    if (r == .ok) continue;
                    if (xfail == null or r == .exact) xfail = r;
                }
            }
            var found = false;
            const deep = u.bits & bit_d != 0;
            for (written.items) |*x| {
                if (x.param != u.param or x.path != u.path) continue;
                found = true;
                x.deep = x.deep or deep;
                if (origin == .exact or (origin == .approx and x.origin == .limit)) x.origin = origin;
                if (xfail) |r| if (x.xfail == null or r == .exact) {
                    x.xfail = r;
                };
            }
            if (!found) try written.append(w.a, .{ .param = u.param, .path = u.path, .origin = origin, .xfail = xfail, .deep = deep });
        };
        for (written.items) |x| {
            if (x.param == 0) {
                // §20.5, §23.6: update writes its message in place — what a
                // send gave up, or what a view event built from the model.
                const at = try w.projPath(msg, x.path, null);
                try w.entryDemandDeep(tok, op, try w.pathName("msg", x.path), if (x.deep) try w.flat(at) else at, &.{}, view_msgs, row, x.origin, x.xfail, x.deep);
                continue;
            }
            var rest: std.ArrayList(Entry) = .empty;
            for (model) |e| if (!w.o.overlap(e.path, x.path)) try rest.append(w.a, e);
            const at = try w.projPath(model, x.path, null);
            // Not Disjoint against this message: what a send put in the
            // model was another send's, given up there (§23.6).
            try w.entryDemandDeep(tok, op, try w.pathName("model", x.path), if (x.deep) try w.flat(at) else at, &.{rest.items}, view_msgs, row, x.origin, x.xfail, x.deep);
        }
        // §20.3: view and subscriptions receive the model to read only.
        for ([_]struct { f: EntryFn, n: []const u8 }{ .{ .f = view, .n = "view" }, .{ .f = subs, .n = "subscriptions" } }) |x| {
            const vop = if (w.mode == .report) try std.fmt.allocPrint(arena, "entry {s}", .{try w.entryName(x.f, x.n)}) else "entry";
            for (x.f.sums) |s| for (s.uses) |u| {
                if (u.bits & bit_w == 0 or u.param != 0) continue;
                try w.demands.append(w.a, .{
                    .kind = .value,
                    .token = tok,
                    .op = vop,
                    .base = try w.pathName("model", u.path),
                    .base_local = none,
                    .base_path = eps,
                    .point = w.point,
                    .frame = w.frame,
                    .ctx = w.ctx,
                    .element = false,
                    .accept = .param,
                    .holders = &.{},
                    .fixed = .{ .verdict = .{ .rejected = .read_only }, .detail = try std.fmt.allocPrint(arena, "the runtime hands {s} the model to read only (§20.3)", .{x.n}) },
                });
            };
        }
        return w.entryResult(inst);
    }

    /// Whether `update`'s message type may hold a cell: the type of the
    /// record literal's `update` field, when the walk has it.
    fn messageTracked(w: *Walker, arg: Inst.Index) Allocator.Error!bool {
        if (w.bir.instTag(arg) != .record) return true;
        const sym = w.o.in.interner.find("update") orelse return true;
        for (w.bir.extraSlice(Bir.inlineRange(w.bir.instData(arg)), Bir.Field)) |fl| {
            if (w.bir.symbol(fl.name) != sym) continue;
            const v = w.instType(fl.value) orelse return true;
            switch (w.store.resolvedContent(v)) {
                .structure => |st| switch (st) {
                    .func => |fun| {
                        const ps = w.store.vars(fun.params);
                        if (ps.len == 0) return true;
                        return w.trackedVar(ps[0]);
                    },
                    else => return true,
                },
                else => return true,
            }
        }
        return true;
    }

    /// What a function the runtime calls escapes of the model: `E`, or `J`
    /// alone, §18.6's conservative escape, which the line names (§20.4).
    fn entryEscape(w: *Walker, inst: Inst.Index, av: AV, bits: u8) Allocator.Error!void {
        if (bits & bit_e != 0) return w.escape(av, w.point);
        if (bits & bit_j != 0) try w.escapeWhy(av, w.point, inst);
    }

    /// §20.5, §23.6: the cells the messages `view` builds may carry, anywhere
    /// in a message: its result's cells, closures expanded, but its own root.
    fn viewMessages(w: *Walker, inst: Inst.Index, view: EntryFn, model: AV, conds: bool, result_ty: ?Var) Allocator.Error!AV {
        if (view.sums.len == 0) return &.{};
        // The model's own cells, and every list the view made: a markup value
        // keeps its handlers from one dispatch to the next (P3), so a list a
        // handler's message holds may be handed over twice. The markup's own
        // node — what the view returns at its root — is no message.
        var held: std.ArrayList(Entry) = .empty;
        const result = try w.entryResWith(inst, view, &.{model}, entry_view_ns, conds);
        for (try w.markupEvents(result, result_ty, inst, 0)) |e| {
            // A precise slot projection contains messages, never the markup
            // root. Unknown projected arrivals must remain borrowed too.
            if (result_ty == null and e.path == eps and (try w.reaches(model, &.{e})) == null) continue;
            try held.append(w.a, e);
        }
        // A top-level value whose type can hold no list — a footer, an icon
        // — is markup the view includes, not a message.
        var out: std.ArrayList(Entry) = .empty;
        for (try w.anywhere(try w.norm(held.items), inst)) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind == .shared and c.path == eps and !try w.sharedHoldsList(c.a, c.b)) continue;
            try out.append(w.a, e);
        }
        return w.norm(out.items);
    }

    /// Whether the top-level value `d` of module `m` may hold a list.
    fn sharedHoldsList(w: *Walker, m: u32, d: u32) Allocator.Error!bool {
        if (m >= w.o.in.birs.len) return true;
        return w.o.valueHoldsList(m, d);
    }

    /// A program value: the runtime's, which nothing in the program reads.
    fn entryResult(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .top, .a = 0 });
    }

    /// How an entry line names the function: `Main.update`, or `<lambda>`.
    fn entryName(w: *Walker, f: EntryFn, field: []const u8) Allocator.Error![]const u8 {
        for (f.classes) |cls| switch (cls) {
            .func => |t| return w.qualified(t),
            .closure, .send => {},
        };
        return std.fmt.allocPrint(w.o.out.allocator(), "<{s}>", .{field});
    }

    /// `model.todos`: a root's name with a path.
    fn pathName(w: *Walker, root: []const u8, p: u32) Allocator.Error![]const u8 {
        if (w.mode != .report) return root;
        return std.fmt.allocPrint(w.o.out.allocator(), "{s}{s}", .{ root, try w.o.pathText(p) });
    }

    /// A demand at the entry (§20.6): a call-site demand on the entry model
    /// at one path, or on the message.
    fn entryDemandDeep(w: *Walker, tok: u32, op: []const u8, text: []const u8, base: AV, others: []const AV, payload_from: AV, row: EntryRow, origin: Origin, xfail: ?Rely, deep: bool) Allocator.Error!void {
        try w.demandOn(.{
            .kind = .callsite,
            .token = tok,
            .op = op,
            .base_text = text,
            .base_ref = null,
            .base_ty = null,
            .base = base,
            .others = others,
            .origin = origin,
            .xfail = xfail,
            .entry = row,
            .payload_from = payload_from,
            .deep = deep,
        });
    }

    fn evalMethod(w: *Walker, inst: Inst.Index) Allocator.Error!AV {
        const b = w.bir;
        const data = b.instData(inst);
        const mc = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
        const rest = b.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
        const all = try w.a.alloc(Inst.Index, rest.len + 1);
        all[0] = @fromBackingInt(@intCast(data.lhs));
        @memcpy(all[1..], rest);
        try w.evidenceSight(inst);
        if (w.methodTarget(inst)) |t| return w.callTarget(inst, t, all);
        return w.conservative(inst, all, &.{}, null, "", false);
    }

    /// Where a function the dispatch table passes as evidence writes a
    /// parameter: its calls are not seen (§16.5).
    fn evidenceSight(w: *Walker, inst: Inst.Index) Allocator.Error!void {
        if (w.m >= w.o.in.dispatch.len) return;
        const dt = &w.o.in.dispatch[w.m];
        const site = dt.siteOf(inst) orelse return;
        for (dt.argsAt(site.evidence)) |ti| try w.evidenceTerm(dt, ti, w.token(inst), 0);
    }

    fn evidenceTerm(w: *Walker, dt: *const Dispatch, ti: Dispatch.TermIndex, tok: u32, depth: u32) Allocator.Error!void {
        if (depth > 8) return;
        const t = dt.term(ti);
        if (w.termTarget(t)) |target| {
            if (try w.o.ensureSummary(target.m, target.d)) |s| if (s.writesAny()) {
                try w.valueLine(tok, try w.qualified(target), .pending, "it is passed as evidence, whose calls the checker does not see", "", false);
            };
        }
        for (dt.argsOfTerm(ti)) |x| try w.evidenceTerm(dt, x, tok, depth + 1);
    }

    /// The function parameter of the declaration an abstract value is,
    /// when it is exactly one.
    fn fnParamOf(w: *Walker, av: AV) ?u32 {
        if (av.len != 1 or av[0].path != eps) return null;
        var c = w.cells.items[av[0].cell];
        if (c.kind == .env) {
            const held = w.local_av[c.a] orelse return null;
            if (held.len != 1 or held[0].path != eps or c.path != eps) return null;
            c = w.cells.items[held[0].cell];
        }
        if (c.kind != .param or c.b != 0 or c.path != eps) return null;
        for (w.params, 0..) |p, i| if (p.int() == c.a and w.fn_state.items[i].is_fn) return @intCast(i);
        return null;
    }

    /// `send`: a send value (§23.2), whose class gives up everything it is
    /// handed.
    const Class = union(enum) { closure: u32, func: Target, send };

    /// Whether a cell is the parameter of a lambda written at a send
    /// position (§23.4).
    fn isSend(w: *const Walker, c: Cell) bool {
        return c.kind == .param and c.b == 1 and c.path == eps and w.instCol(bool, w.send_params, c.a, false);
    }

    /// The classes a function value may have: the lambdas, local functions
    /// and top-level functions it may be (§16.5). Empty when any part of it
    /// is something else.
    fn classesOf(w: *Walker, av: AV) Allocator.Error![]const Class {
        var out: std.ArrayList(Class) = .empty;
        for (av) |e| {
            // What a closure a callee's result carried holds sits beside
            // it, under `◇` (§24.9): its captures, not another function.
            if (w.o.firstStep(e.path)) |s| if (s.kind == .env) continue;
            if (e.path != eps) return &.{};
            const c = w.cells.items[e.cell];
            if (w.isSend(c)) {
                try out.append(w.a, .send);
                continue;
            }
            switch (c.kind) {
                .closure => try out.append(w.a, .{ .closure = c.a }),
                .func => try out.append(w.a, .{ .func = .{ .m = c.a, .d = c.b } }),
                .env => {
                    const held = w.local_av[c.a] orelse return &.{};
                    if (c.path != eps) return &.{};
                    for (held) |h| {
                        if (h.path != eps) return &.{};
                        const hc = w.cells.items[h.cell];
                        if (w.isSend(hc)) {
                            try out.append(w.a, .send);
                            continue;
                        }
                        switch (hc.kind) {
                            .closure => try out.append(w.a, .{ .closure = hc.a }),
                            .func => try out.append(w.a, .{ .func = .{ .m = hc.a, .d = hc.b } }),
                            else => return &.{},
                        }
                    }
                },
                else => return &.{},
            }
        }
        return out.items;
    }

    /// §6.1.
    fn conservative(w: *Walker, inst: Inst.Index, args: []const Inst.Index, callee_av: AV, callee: ?Inst.Index, name: []const u8, foreign: bool) Allocator.Error!AV {
        const avs = try w.evalOperands(args, true);
        w.popPending(avs.len);
        return w.conservativeAV(inst, args, avs, callee_av, callee, name, foreign);
    }

    fn conservativeAV(w: *Walker, inst: Inst.Index, args: []const Inst.Index, avs: []const AV, callee_av: AV, callee: ?Inst.Index, name: []const u8, foreign: bool) Allocator.Error!AV {
        w.point += 1;
        const tok = w.token(inst);
        for (args) |x| try w.useOperand(x, tok, &.{});
        if (callee) |c| try w.useOperand(c, tok, &.{});
        try w.useTemporaries(args, avs, tok);
        if (callee) |c| try w.useTemporaries(&.{c}, &.{callee_av}, tok);
        for (avs) |av| try w.sight(av, if (name.len > 0) .{ .no_summary = name } else .{ .pending = "it is passed where the checker cannot see its calls" }, tok);
        if (foreign) for (avs) |av| try w.escapeCapturesOf(av, w.point, inst);
        const ty = w.instType(inst);
        if (ty) |v| if (!try w.trackedVar(v)) return &.{};
        var out: std.ArrayList(Entry) = .empty;
        const fresh = try w.cell(.{ .kind = .result, .a = inst.int(), .ty = w.instTypeOpt(inst) });
        try out.append(w.a, .{ .path = eps, .cell = fresh });
        const any = try w.o.child(eps, .any, 0);
        var from: std.ArrayList(AV) = .empty;
        try from.appendSlice(w.a, avs);
        try from.append(w.a, callee_av);
        for (from.items) |av| {
            for (try w.expand(av)) |e| {
                const c = w.cells.items[e.cell];
                if (c.kind == .closure or c.kind == .func) continue;
                if (ty) |r| if (c.ty.unwrap()) |ct| if (!try w.o.mayHold(w.store, r, ct, 0)) continue;
                try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = inst.int() + 1 });
            }
        }
        return w.norm(out.items);
    }

    /// A `foreign` or `Js` call: its arguments escape, its result is ⊤
    /// (§6.1 item 2).
    fn escapeCall(w: *Walker, inst: Inst.Index, args: []const Inst.Index, name: []const u8) Allocator.Error!AV {
        const avs = try w.evalOperands(args, false);
        w.popPending(avs.len);
        try w.consume(args, w.token(inst));
        try w.useTemporaries(args, avs, w.token(inst));
        for (avs) |av| {
            try w.sight(av, .{ .no_summary = name }, w.token(inst));
            try w.escape(av, w.point);
        }
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .top, .a = 0 });
    }

    /// A call of the declaration's own function parameter `j` (§16.4 item
    /// 4): each argument is a supply, owned when it passes the four
    /// conditions at the call, and the result is that parameter's result.
    fn callbackCall(w: *Walker, inst: Inst.Index, j: u32, args: []const Inst.Index, callee: Inst.Index) Allocator.Error!AV {
        const avs = try w.evalOperands(args, true);
        w.popPending(avs.len);
        w.point += 1;
        const tok = w.token(inst);
        for (args) |x| try w.useOperand(x, tok, &.{});
        try w.useOperand(callee, tok, &.{});
        try w.useTemporaries(args, avs, tok);
        for (avs) |av| try w.sight(av, .{ .pending = "it is passed to a function parameter, whose class is not known here" }, tok);
        const st = &w.fn_state.items[j];
        st.calls = if (w.recursive or st.calls != .zero) .many else .once;
        w.cb_args[inst.int() - w.decl.inst_start.int()] = try w.unionOf(avs);
        for (avs, 0..) |av, k| {
            if (av.len == 0) continue;
            var others: std.ArrayList(AV) = .empty;
            for (avs, 0..) |x, i| if (i != k) try others.append(w.a, x);
            const probe = try w.probeDemand(inst, av, others.items);
            try w.supplies.append(w.a, .{ .fun = j, .k = @intCast(k), .path = eps, .av = av, .probe = probe, .cond = try w.deepCond(av) });
        }
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .cbres, .a = j, .b = inst.int(), .ty = w.instTypeOpt(inst) });
    }

    /// The closure whose body frame `frame` is.
    fn frameClosure(w: *const Walker, frame: u32) ?u32 {
        if (frame == 0) return null;
        var ci = w.closures.items.len;
        while (ci > 0) {
            ci -= 1;
            if (w.closures.items[ci].frame == frame and w.closures.items[ci].params.len > 0) return @intCast(ci);
        }
        return null;
    }

    /// §18.9: a call of the declaration's function parameter `j` inside the
    /// lambda `ci`. Its arguments are probed here, in the lambda; the call
    /// itself is made wherever the lambda runs, where `applyEnvCalls` makes
    /// it a call of `π_j`. The result is that parameter's result.
    fn envCall(w: *Walker, inst: Inst.Index, ci: u32, j: u32, args: []const Inst.Index, callee: Inst.Index) Allocator.Error!AV {
        const avs = try w.evalOperands(args, true);
        w.popPending(avs.len);
        w.point += 1;
        const tok = w.token(inst);
        for (args) |x| try w.useOperand(x, tok, &.{});
        try w.useOperand(callee, tok, &.{});
        try w.useTemporaries(args, avs, tok);
        for (avs) |av| try w.sight(av, .{ .pending = "it is passed to a function parameter, whose class is not known here" }, tok);
        w.cb_args[inst.int() - w.decl.inst_start.int()] = try w.unionOf(avs);
        const probes = try w.a.alloc(u32, avs.len);
        for (avs, probes, 0..) |av, *p, k| {
            p.* = none;
            if (av.len == 0) continue;
            var others: std.ArrayList(AV) = .empty;
            for (avs, 0..) |x, i| if (i != k) try others.append(w.a, x);
            p.* = try w.probeDemand(inst, av, others.items);
        }
        try w.env_calls.append(w.a, .{ .closure = ci, .j = j, .inst = inst, .args = avs, .probes = probes });
        if (!try w.isTracked(inst)) return &.{};
        return w.single(.{ .kind = .cbres, .a = j, .b = inst.int(), .ty = w.instTypeOpt(inst) });
    }

    /// Where the lambda `ci` is checked: by callee `s`, handed it as its
    /// parameter `jj` at the call `ctx.inst`, or (`s` null) called here
    /// with `ctx.avs`. Each call it makes of a function parameter of the
    /// declaration becomes a call here, its arguments what the callee
    /// supplies the lambda (§18.9).
    fn applyEnvCalls(w: *Walker, ci: u32, s: ?*const Summary, jj: u32, ctx: InstCtx) Allocator.Error!void {
        for (w.env_calls.items) |ec| {
            if (ec.closure != ci) continue;
            const st = &w.fn_state.items[ec.j];
            if (w.frame != 0) {
                st.seen = false;
                continue;
            }
            const calls: Calls = if (s) |cs| (if (cs.funOf(jj)) |f| f.calls else .many) else .once;
            if (calls == .zero) continue;
            if (s) |cs| if (cs.funOf(jj)) |f| {
                st.seen = st.seen and f.seen;
            };
            st.calls = if (w.recursive or st.calls != .zero or calls == .many) .many else .once;
            for (ec.args, ec.probes, 0..) |av, probe, k| {
                if (av.len == 0) continue;
                var owned = true;
                var taken = false;
                var from: std.ArrayList(u32) = .empty;
                const cells = try w.fromLambda(av, ci, s, jj, ctx, &owned, &taken, &from);
                // Disjoint against every argument but the lambda and the
                // ones the supplied cells come from.
                var others: std.ArrayList(AV) = .empty;
                for (ctx.avs, 0..) |x, i| {
                    if (i == jj or std.mem.indexOfScalar(u32, from.items, @intCast(i)) != null) continue;
                    try others.append(w.a, x);
                }
                const probe2 = if (owned and cells.len > 0) try w.probeDemand(ctx.inst, cells, others.items) else none;
                try w.supplies.append(w.a, .{ .fun = ec.j, .k = @intCast(k), .path = eps, .av = cells, .probe = probe, .probe2 = probe2, .owned = owned, .cond = try w.deepCond(cells), .taken = taken });
            }
        }
    }

    /// A value in lambda `ci`'s vocabulary, in the enclosing body's: its
    /// parameters as the callee supplies them (or as the call passes them),
    /// its captures as the body holds them. `owned` falls when a supply it
    /// rests on is borrowed; `taken` rises when one is destructive.
    fn fromLambda(w: *Walker, av: AV, ci: u32, s: ?*const Summary, jj: u32, ctx: InstCtx, owned: *bool, taken: *bool, from: *std.ArrayList(u32)) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        for (av) |e| {
            const c = w.cells.items[e.cell];
            if (w.lambdaParam(c)) |lp| if (lp[0] == ci) {
                var parts: std.ArrayList(AV) = .empty;
                if (s) |cs| {
                    for (cs.supply) |sp| {
                        if (sp.fun != jj or sp.k != lp[1]) continue;
                        if (!sp.owned) owned.* = false;
                        if (sp.prov.taken) taken.* = true;
                        if (sp.prov.kind == .param) try from.append(w.a, sp.prov.a);
                        const at = try w.under(try w.instProv(sp.prov, ctx), sp.path);
                        try parts.append(w.a, try w.projPath(at, c.path, null));
                    }
                } else if (lp[1] < ctx.avs.len) {
                    try from.append(w.a, lp[1]);
                    try parts.append(w.a, try w.projPath(ctx.avs[lp[1]], c.path, null));
                }
                try out.appendSlice(w.a, try w.under(try w.unionOf(parts.items), e.path));
                continue;
            };
            if (c.kind == .env) {
                const held = w.local_av[c.a] orelse continue;
                try out.appendSlice(w.a, try w.under(try w.projPath(held, c.path, null), e.path));
                continue;
            }
            try out.append(w.a, e);
        }
        return w.norm(out.items);
    }

    /// Whether `s` reads, keeps, returns or writes its parameter `i` at a
    /// path overlapping `q`.
    fn touches(w: *const Walker, s: *const Summary, i: u32, q: u32) bool {
        for (s.uses) |u| {
            if (u.param != i or noUse(u.bits)) continue;
            if (w.o.overlap(u.path, q)) return true;
        }
        return false;
    }

    /// No bits: no use at the call.
    fn noUse(bits: u8) bool {
        return bits == 0;
    }

    /// §16.4: a call whose callee has a summary.
    fn applySummary(w: *Walker, inst: Inst.Index, callee: Callee, args: []const Inst.Index, callee_av: AV, callee_inst: ?Inst.Index) Allocator.Error!AV {
        const s = callee.sum;
        // §23.4: a lambda written at a send position: its parameter there
        // is a send, known before its body is walked.
        for (s.funs) |f| {
            if (f.send == none or f.param >= args.len) continue;
            const arg = args[f.param];
            if (w.bir.instTag(arg) != .lambda) continue;
            const ps = w.bir.extraSlice(w.bir.subRange(@fromBackingInt(@intCast(w.bir.instData(arg).lhs))), Inst.Index);
            if (f.send < ps.len) {
                const at = ps[f.send].int() -% w.decl.inst_start.int();
                if (at < w.send_params.len) w.send_params[at] = true;
            }
        }
        const avs = try w.a.alloc(AV, args.len);
        for (args, avs, 0..) |arg, *v, i| {
            const outer = w.ctx;
            // §25.4: `Maybe.map m f` is walked whole in arm `Just`, `m`
            // included, which is sound only because `isMaybeJoin` keeps `m`
            // and `d` variable paths and `f` a lambda or top-level value —
            // operands whose evaluation writes nothing. Widening any of
            // them must move its evaluation out of the arm.
            if (w.joinArm(inst, i)) |arm| w.ctx = arm;
            v.* = try w.eval(arg);
            w.ctx = outer;
            const is_ref = (try w.refPath(arg)) != null;
            try w.pending.append(w.a, .{ .av = v.*, .frame = w.frame, .token = w.token(arg), .is_ref = is_ref, .by_call = true, .consumer = s, .arg = @intCast(i) });
        }
        w.popPending(args.len);
        w.point += 1;
        const tok = w.token(inst);
        // 1. Uses, at the paths the callee touches.
        for (args, avs, 0..) |arg, av, i| {
            const pi: u32 = @intCast(i);
            if (try w.refPath(arg)) |r| {
                const outer = w.ctx;
                defer w.ctx = outer;
                if (w.joinArm(inst, i)) |arm| w.ctx = arm;
                w.use_at = .{ w.rootToken(arg), w.token(arg) };
                defer w.use_at = .{ none, none };
                for (s.uses) |u| {
                    if (u.param != pi or noUse(u.bits)) continue;
                    try w.useAt(r.local, try w.o.concat(r.path, u.path), tok, &.{});
                }
            } else if (w.touches(s, pi, eps)) {
                try w.useCaptures(av, tok);
            }
        }
        if (callee_inst) |c| {
            try w.useOperand(c, tok, &.{});
            try w.useTemporaries(&.{c}, &.{callee_av}, tok);
        }
        // §23.3: a function parameter handed to a send position takes the
        // fact before anything the callee keeps of it is looked at.
        if (w.frame == 0) for (s.funs) |f| {
            if (f.send == none or f.param >= args.len) continue;
            if (w.fnParamOf(avs[f.param])) |jj| if (w.fn_state.items[jj].send == none) {
                w.fn_state.items[jj].send = f.send;
            };
        };
        // A lambda called here makes its calls of the declaration's function
        // parameters here (§18.9).
        if (callee.closure != none) try w.applyEnvCalls(callee.closure, null, 0, .{ .inst = inst, .s = s, .avs = avs, .depth = 0 });
        // 2. What the callbacks escape, before the callee writes (§16.4 item 4).
        for (s.funs) |f| {
            if (!hasActual(s, args.len, f.param)) continue;
            try w.callbackEscapes(inst, s, f.param, avs);
        }
        // §18.4 item 3: what the callee relied on, at the arguments; a
        // failure is reported on the call-site demand of the argument it
        // names, or on a line of its own when there is none.
        const xfail = try w.a.alloc(?Rely, args.len);
        @memset(xfail, null);
        for (s.xreq) |x| {
            const k = try w.instXSum(.{ .atoms = &.{x} }, .{ .inst = inst, .s = s, .avs = avs, .closure = callee.closure, .depth = 0 });
            const r = try w.rely(k, w.frame);
            if (r == .ok) continue;
            const i = xreqParam(x) orelse continue;
            if (i >= args.len) continue;
            if (xfail[i] == null or r == .exact) xfail[i] = r;
        }
        // 3. W: the caller's side of a written parameter.
        for (s.uses) |u| {
            if (u.bits & bit_w == 0 or u.param >= args.len) continue;
            // A named writer's line keeps its slice-1 form; any other call
            // names the summary that wrote.
            const note = if (w.mode != .report or s.asserted or std.mem.startsWith(u8, callee.op, "List.")) "" else try std.fmt.allocPrint(w.o.out.allocator(), "{s} writes π{d}{s}", .{ callee.name, u.param + 1, try w.o.pathText(u.path) });
            try w.callSiteDemandDeep(inst, callee.op, args, avs, callee_av, u.param, u.path, note, if (s.limit != .none) .limit else if (u.bits & bit_x == 0) .approx else .exact, xfail[u.param], u.bits & bit_d != 0);
            xfail[u.param] = null;
        }
        for (xfail, 0..) |f, i| {
            const r = f orelse continue;
            try w.demands.append(w.a, .{
                .kind = .value,
                .token = tok,
                .op = callee.op,
                .base = try w.baseText(args[i]),
                .base_local = none,
                .base_path = eps,
                .point = w.point,
                .frame = w.frame,
                .ctx = w.ctx,
                .element = false,
                .accept = .param,
                .holders = &.{},
                .fixed = .{ .verdict = .{ .rejected = .exclusive }, .detail = try w.exclusiveText(args[i]) },
                .prelim = .{ .cause = .exclusive, .detail = "", .approx = r == .approx },
            });
        }
        // 4. E, and what the summary keeps of a function value.
        for (s.uses) |u| {
            if (u.bits & (bit_e | bit_j) == 0 or u.param >= args.len) continue;
            const at = try w.projPath(avs[u.param], u.path, null);
            try w.sight(at, .{ .pending = if (w.mode != .report) "" else try std.fmt.allocPrint(w.o.out.allocator(), "{s} keeps it", .{callee.name}) }, tok);
            // Kept only by a function value handed to JavaScript (§18.6):
            // the escape says so.
            if (u.bits & bit_e == 0) try w.escapeWhy(at, w.point, inst) else try w.escape(at, w.point);
        }
        // Callbacks.
        for (s.funs) |f| {
            if (!hasActual(s, args.len, f.param)) continue;
            try w.checkCallback(inst, callee, args, avs, f.param);
        }
        // 5. The result.
        const ty = w.instType(inst);
        if (ty) |v| if (!try w.trackedVar(v)) return &.{};
        const arg_types = try w.a.alloc(?Var, args.len);
        for (args, arg_types) |arg, *t| t.* = w.instType(arg);
        const res = try w.instRes(s, .{ .inst = inst, .s = s, .avs = avs, .closure = callee.closure, .depth = 0, .merge_fresh = callee.merge_fresh, .arg_types = arg_types, .result_ty = ty, .take = s.asserted });
        // An approximate entry may name an argument the result's type
        // cannot be (§6.1's type filter, thesis §3.8): a `Js` coercion's
        // result is never its argument at another type.
        const rt = ty orelse return res;
        var kept: std.ArrayList(Entry) = .empty;
        for (res) |e| {
            if (e.path == eps and e.approx != 0) {
                if (w.cells.items[e.cell].ty.unwrap()) |ct| if (!try w.o.mayShare(w.store, rt, ct, 0)) continue;
            }
            try kept.append(w.a, e);
        }
        return kept.items;
    }

    /// The argument an `xreq` atom names first: a parameter's or a callback's.
    fn xreqParam(x: XAtom) ?u32 {
        for ([_]Prov{ x.a, x.b }) |p| switch (p.kind) {
            .param, .cb => return p.a,
            else => {},
        };
        return null;
    }

    /// A rejection's sentence for contents that may share (§18.4).
    fn exclusiveText(w: *Walker, inst: Inst.Index) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(w.o.out.allocator(), "the elements of {s} may share one list", .{try w.baseText(inst)});
    }

    /// The cells the callbacks handed to this call escape (§16.4 item 4),
    /// joined to Esc just before the call's point, so that a write the
    /// callee makes after calling them sees the escape.
    fn callbackEscapes(w: *Walker, inst: Inst.Index, s: *const Summary, j: u32, avs: []const AV) Allocator.Error!void {
        const classes = try w.classesOf((try w.actualOf(s, avs, j)) orelse return);
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse continue;
            for (c.uses) |u| {
                if (u.bits & (bit_e | bit_j) == 0) continue;
                for (s.supply) |e| {
                    if (e.fun != j or e.k != u.param or !w.o.overlap(e.path, u.path)) continue;
                    const cells = try w.instProv(e.prov, .{ .inst = inst, .s = s, .avs = avs, .depth = 1 });
                    try w.escape(cells, w.point - 1);
                }
            }
            if (cls == .closure) try w.escapeCaptures(cls.closure, w.point - 1);
        }
    }

    /// What a lambda escaped of the cells it captured, joined to Esc where
    /// the lambda runs.
    fn escapeCaptures(w: *Walker, ci: u32, at: u32) Allocator.Error!void {
        for (w.closures.items[ci].env_escapes) |cap| {
            const held = w.local_av[cap.local] orelse continue;
            try w.escape(try w.projPath(held, cap.path, null), at);
        }
    }

    fn classSummary(w: *Walker, cls: Class) Allocator.Error!?*const Summary {
        return switch (cls) {
            .closure => |ci| w.closures.items[ci].class,
            .func => |t| w.o.ensureSummary(t.m, t.d),
            .send => &send_class,
        };
    }

    const callback_ns_stride: u32 = 1000;

    const InstCtx = struct {
        inst: Inst.Index,
        s: *const Summary,
        avs: []const AV,
        /// A lambda's class: its closure, whose captures `◇` names.
        closure: u32 = none,
        depth: u32,
        /// A callback's result being instantiated, and what it stands for
        /// so far: a fold hands its callback its own previous result.
        self_j: u32 = none,
        self_av: AV = &.{},
        /// The callee is in the recursive group being solved: its fresh
        /// cells are one cell per call, so the numbering stays finite.
        merge_fresh: bool = false,
        /// §20.4: the functions an entry instantiates at one call number
        /// their fresh cells apart.
        fresh_ns: u32 = 0,
        /// §20.4: the fixpoint's rounds compute cells only; the round that
        /// settles lowers their conditions once.
        conds: bool = true,
        /// Condition rounds cannot record speculative escapes or diagnostics.
        effects: bool = true,
        /// At the call itself: the arguments' types and the result's.
        arg_types: []const ?Var = &.{},
        result_ty: ?Var = null,
        /// Allocations represented by fresh result provenance while computing
        /// a callback's shape. Supplies and projected arrivals do not add cells.
        callback_fresh: ?*std.ArrayList(u32) = null,
        /// The traversal primitive's own result: a taken element stays
        /// taken (§18.5). Anywhere else a supply or result that names one
        /// instantiates to the element itself.
        take: bool = false,
    };

    /// `s.res` instantiated at the call (§16.4 item 6).
    fn instRes(w: *Walker, s: *const Summary, ctx: InstCtx) Allocator.Error!AV {
        // `several` below reads neighbours: `normalize` sorts `res` by path.
        if (std.debug.runtime_safety and s.res.len > 1) for (s.res[1..], 0..) |r, i| std.debug.assert(s.res[i].path <= r.path);
        var out: std.ArrayList(Entry) = .empty;
        for (s.res, 0..) |r, i| {
            // `res` is sorted by path: another entry at this path is a neighbour.
            const several = (i > 0 and s.res[i - 1].path == r.path) or (i + 1 < s.res.len and s.res[i + 1].path == r.path);
            // An approximate entry may name an argument the result's type
            // cannot be (§16.4 item 6): such an argument is never the
            // result, whatever its cells are.
            if ((several or r.approx) and r.path == eps and r.prov.kind == .param and r.prov.path == eps and r.prov.a < ctx.arg_types.len) {
                if (ctx.result_ty) |rt| if (ctx.arg_types[r.prov.a]) |at| if (!try w.o.mayShare(w.store, rt, at, 0)) continue;
            }
            const cells = try w.instProv(r.prov, ctx);
            // §18.3: a fresh cell starts at the summary's condition, and a
            // parameter's is lowered by it.
            if (ctx.conds) switch (r.prov.kind) {
                .fresh, .esc => {
                    const k = try w.instXSum(r.xc, ctx);
                    for (cells) |e| if (e.path == eps) {
                        try w.initCond(e.cell, k);
                        try w.initSpine(e.cell, try w.instXSum(r.sc, ctx));
                    };
                },
                .param => if (r.xc.no != 0 or r.xc.atoms.len != 0) {
                    const k = try w.instXSum(r.xc, ctx);
                    for (cells) |e| if (e.path == eps) try w.lowerCond(e.cell, k);
                },
                else => {},
            };
            if (ctx.conds and r.prov.kind == .param) for (cells) |e| if (e.path == eps) {
                try w.lowerSpine(e.cell, try w.instXSum(r.sc, ctx));
            };
            var av = try w.under(cells, r.path);
            if (several or r.approx) av = try w.approxAll(av, ctx.inst);
            try out.appendSlice(w.a, av);
        }
        return w.norm(out.items);
    }

    fn instProv(w: *Walker, p: Prov, ctx: InstCtx) Allocator.Error!AV {
        switch (p.kind) {
            .param => {
                if (p.a >= ctx.avs.len) return &.{};
                const av = try w.projPath(ctx.avs[p.a], p.path, null);
                if (!p.taken or !ctx.take) return av;
                // The traversal primitive's element, taken out (§18.5): a
                // cell that arrived from outside stands for it taken.
                const out = try w.a.alloc(Entry, av.len);
                for (av, out) |e, *x| {
                    x.* = e;
                    if (e.path != eps) continue;
                    switch (w.cells.items[e.cell].kind) {
                        .param, .result, .env, .cbres => x.cell = try w.cell(.{ .kind = .taken, .a = e.cell, .b = ctx.inst.int() }),
                        else => {},
                    }
                }
                return w.norm(out);
            },
            .fresh, .esc => {
                const base_k = if (ctx.merge_fresh) 1 else p.a;
                const k = (if (ctx.depth == 0) base_k else base_k + callback_ns_stride * ctx.depth) + ctx.fresh_ns;
                const ty: Var.Optional = if (ctx.depth == 0) w.instTypeOpt(ctx.inst) else .none;
                const av = try w.single(.{ .kind = .result, .a = ctx.inst.int(), .b = @max(k, 1), .ty = ty });
                if (p.kind == .fresh) if (ctx.callback_fresh) |made| for (av) |e| {
                    if (std.mem.indexOfScalar(u32, made.items, e.cell) == null) try made.append(w.a, e.cell);
                };
                if (p.kind == .esc and ctx.effects) try w.escape(av, w.point);
                return av;
            },
            .shared => return w.single(.{ .kind = .shared, .a = p.a, .b = p.b, .path = p.path }),
            .top => return w.single(.{ .kind = .top, .a = if (ctx.s.limit != .none or p.a == 1) 1 else 0 }),
            .env => {
                if (ctx.closure == none) return w.single(.{ .kind = .top, .a = 0 });
                // A carried lambda's capture: what the callee's binding said
                // it held, as this body holds it (§24.9).
                if (w.closures.items[ctx.closure].carried) return w.carriedEnv(ctx.closure, p);
                // Inside a summary's frame the capture stays symbolic. Looking
                // through it here would substitute the caller's cells into
                // the recursive class and erase captured writes (§29).
                if (p.a >= w.local_av.len) return w.single(.{ .kind = .top, .a = 0 });
                if (w.local_av[p.a] == null or w.local_frame[p.a] != w.frame)
                    return w.single(.{ .kind = .env, .a = p.a, .path = p.path });
                return w.projPath(w.local_av[p.a].?, p.path, null);
            },
            .klass => return w.carry(p, ctx),
            .cb => {
                // A carried lambda's call of the function parameter of the
                // declaration it was written in: of what this body passed
                // there (§24.9).
                if (p.b == 1 and ctx.closure != none and w.closures.items[ctx.closure].carried) {
                    for (w.closures.items[ctx.closure].cb_avs) |cb| if (cb.j == p.a) {
                        if (w.frame == 0) if (w.fnParamOf(cb.av) orelse try w.slotOf(cb.av)) |jj| {
                            return w.projPath(try w.single(.{ .kind = .cbres, .a = jj, .b = ctx.inst.int() }), p.path, null);
                        };
                    };
                    return w.single(.{ .kind = .top, .a = 0 });
                }
                // A lambda's class: the enclosing declaration's callback result (§18.9).
                if (p.b == 1) return if (w.frame == 0) w.projPath(try w.single(.{ .kind = .cbres, .a = p.a, .b = ctx.inst.int() }), p.path, null) else w.single(.{ .kind = .top, .a = 0 });
                if (!hasActual(ctx.s, ctx.avs.len, p.a)) return w.single(.{ .kind = .top, .a = 0 });
                const whole = if (p.a == ctx.self_j) ctx.self_av else if (ctx.depth >= inst_depth) try w.single(.{ .kind = .top, .a = 0 }) else try w.instCb(p.a, ctx);
                return w.projPath(whole, p.path, null);
            },
        }
    }

    /// What the actual for function parameter `j` returns when the callee
    /// calls it (§16.4 item 6). A callee may hand the callback its own
    /// earlier result (a fold's accumulator), so this is a least fixpoint,
    /// iterated from nothing; one that does not settle adds `⊤`.
    fn instCb(w: *Walker, j: u32, ctx: InstCtx) Allocator.Error!AV {
        const actual = (try w.actualOf(ctx.s, ctx.avs, j)) orelse return w.single(.{ .kind = .top, .a = 0 });
        if (w.fnParamOf(actual) orelse try w.slotOf(actual)) |jj| {
            if (w.frame == 0) return w.single(.{ .kind = .cbres, .a = jj, .b = ctx.inst.int() });
        }
        const classes = try w.classesOf(actual);
        if (classes.len == 0) return w.unknownCb(j, ctx);
        if (try w.foldAccumulator(j, classes, ctx) != null) return w.instFold(j, classes, ctx);
        var x: AV = &.{};
        var rounds: u32 = 0;
        while (rounds < 4) : (rounds += 1) {
            var inner = ctx;
            inner.self_j = j;
            inner.self_av = x;
            const y = try w.instCbOnce(j, classes, inner);
            const next = try w.unionOf(&.{ x, y });
            if (next.len == x.len) return x;
            x = next;
        }
        return w.unionOf(&.{ x, try w.single(.{ .kind = .top, .a = 0 }) });
    }

    /// A linear feedback edge: one owned initial parameter and the callback's
    /// previous whole result are supplied at the same accumulator position.
    fn foldAccumulator(w: *Walker, j: u32, classes: []const Class, ctx: InstCtx) Allocator.Error!?u32 {
        const s = ctx.s;
        if (s.coarse or s.limit != .none) return null;
        if (!(s.funOf(j) orelse return null).seen) return null;
        var acc: ?u32 = null;
        for (s.supply) |e| {
            if (e.fun == j and e.prov.kind == .cb and e.prov.a == j and e.path == eps and e.prov.path == eps and e.owned) {
                if (acc != null and acc.? != e.k) return null;
                acc = e.k;
            }
        }
        const k = acc orelse return null;
        var start: ?u32 = null;
        for (s.supply) |e| {
            if (e.fun != j or e.k != k) continue;
            if (!e.owned or e.path != eps or e.prov.path != eps) return null;
            switch (e.prov.kind) {
                .cb => if (e.prov.a != j) return null,
                .param => {
                    if (start != null and start.? != e.prov.a) return null;
                    start = e.prov.a;
                },
                else => return null,
            }
        }
        const initial = start orelse return null;
        for (s.uses) |u| if (u.param == initial and u.bits & (bit_e | bit_j) != 0) return null;
        for (s.res) |r| {
            if ((r.prov.kind == .param and r.prov.a == initial) or (r.prov.kind == .cb and r.prov.a == j)) {
                if (r.path != eps or r.prov.path != eps) return null;
            }
        }
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return null;
            if (c.coarse or c.limit != .none or k >= c.params) return null;
            for (c.uses) |u| {
                if (u.param != k) continue;
                if (u.bits & (bit_e | bit_j) != 0) return null;
                if (u.bits & bit_w == 0) continue;
                for (c.res) |r| {
                    if (!w.o.isPrefix(r.path, u.path)) continue;
                    switch (r.prov.kind) {
                        .fresh => {},
                        .param => if (r.prov.a != k or r.prov.path != r.path) return null,
                        else => return null,
                    }
                }
            }
        }
        return k;
    }

    /// Cells use the usual least fixpoint; container conditions use the
    /// greatest must-invariant. Initial/shared cells are never reseeded.
    fn instFold(w: *Walker, j: u32, classes: []const Class, ctx: InstCtx) Allocator.Error!AV {
        var shape: AV = &.{};
        var made: std.ArrayList(u32) = .empty;
        var inner = ctx;
        inner.self_j = j;
        inner.conds = ctx.conds;
        inner.effects = ctx.effects;
        inner.callback_fresh = &made;
        var stable = false;
        for (0..4) |_| {
            inner.self_av = shape;
            const next = try w.unionOf(&.{ shape, try w.instCbOnce(j, classes, inner) });
            if (next.len == shape.len) {
                stable = true;
                break;
            }
            shape = next;
        }
        if (!stable) return w.unionOf(&.{ shape, try w.single(.{ .kind = .top, .a = 0 }) });
        if (!ctx.conds) return shape;
        var future: std.ArrayList(u32) = .empty;
        for (made.items) |cell_id| {
            if (try w.isEscaped(cell_id)) continue;
            const in_shape = for (shape) |e| {
                if (e.cell == cell_id) break true;
            } else false;
            if (!in_shape) continue;
            // A supplied cell never receives a seed, even if abstract fresh
            // ids collide or an entry's namespace numbers exceed the stride.
            var initial = false;
            for (ctx.avs) |av| if ((try w.reaches(av, &.{.{ .path = eps, .cell = cell_id }})) != null) {
                initial = true;
                break;
            };
            if (initial) continue;
            try future.append(w.a, cell_id);
            w.cell_spine.items[cell_id] = cond_yes;
        }
        inner.self_av = shape;
        inner.callback_fresh = null;
        inner.conds = true;
        inner.effects = false;
        var settled = false;
        for (0..round_cap) |_| {
            const before = try w.a.dupe(u32, w.cell_spine.items);
            const escapes_before = w.escaped.items.len;
            const uses = w.uses.items.len;
            const demands = w.demands.items.len;
            const reqs = w.reqs.items.len;
            _ = try w.instCbOnce(j, classes, inner);
            if (std.debug.runtime_safety) {
                std.debug.assert(escapes_before == w.escaped.items.len);
                std.debug.assert(uses == w.uses.items.len);
                std.debug.assert(demands == w.demands.items.len);
                std.debug.assert(reqs == w.reqs.items.len);
            }
            if (std.mem.eql(u32, before, w.cell_spine.items)) {
                settled = true;
                break;
            }
        }
        // Only future cells received optimistic seeds. Every other condition
        // was only weakened by conjunction, so exhaustion keeps those safe facts.
        if (!settled) for (future.items) |c| try w.lowerSpine(c, cond_lost);
        inner.effects = ctx.effects;
        return w.unionOf(&.{ shape, try w.instCbOnce(j, classes, inner) });
    }

    fn instCbOnce(w: *Walker, j: u32, classes: []const Class, ctx: InstCtx) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        var deeper = ctx;
        deeper.depth += 1;
        // Merely supplying a cell is not a callback allocation.
        deeper.callback_fresh = null;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return w.unknownCb(j, ctx);
            // The callback's parameters are what the callee supplies it.
            const params = try w.a.alloc(AV, c.params);
            for (params, 0..) |*pa, k| {
                var parts: std.ArrayList(AV) = .empty;
                for (ctx.s.supply) |e| {
                    if (e.fun != j or e.k != k) continue;
                    try parts.append(w.a, try w.under(try w.instProv(e.prov, deeper), e.path));
                }
                pa.* = try w.unionOf(parts.items);
            }
            const sub: InstCtx = .{ .inst = ctx.inst, .s = c, .avs = params, .closure = if (cls == .closure) cls.closure else none, .depth = ctx.depth + 1, .conds = ctx.conds, .effects = ctx.effects, .callback_fresh = ctx.callback_fresh };
            try out.appendSlice(w.a, try w.instRes(c, sub));
        }
        return w.norm(out.items);
    }

    /// A callback with no class: §6.1's conservative result over what the
    /// callee supplies it and what it holds.
    fn unknownCb(w: *Walker, j: u32, ctx: InstCtx) Allocator.Error!AV {
        var out: std.ArrayList(Entry) = .empty;
        const fresh = try w.cell(.{ .kind = .result, .a = ctx.inst.int(), .b = 0 });
        try out.append(w.a, .{ .path = eps, .cell = fresh });
        const any = try w.o.child(eps, .any, 0);
        var from: std.ArrayList(AV) = .empty;
        for (ctx.s.supply) |e| {
            if (e.fun != j) continue;
            try from.append(w.a, try w.instProv(e.prov, .{ .inst = ctx.inst, .s = ctx.s, .avs = ctx.avs, .closure = ctx.closure, .depth = ctx.depth + 1, .effects = ctx.effects }));
        }
        if (try w.actualOf(ctx.s, ctx.avs, j)) |actual| try from.append(w.a, actual);
        for (from.items) |av| for (try w.expand(av)) |e| {
            const c = w.cells.items[e.cell];
            if (c.kind == .closure or c.kind == .func) continue;
            try out.append(w.a, .{ .path = any, .cell = e.cell, .approx = ctx.inst.int() + 1 });
        };
        return w.norm(out.items);
    }

    /// A call-site demand (§16.4 item 3): argument `i`'s cells at `q`,
    /// Disjoint against every other argument and every other path of `i`.
    fn callSiteDemand(w: *Walker, inst: Inst.Index, op: []const u8, args: []const Inst.Index, avs: []const AV, i: u32, q: u32, note: []const u8, origin: Origin, xfail: ?Rely) Allocator.Error!void {
        return w.callSiteDemandDeep(inst, op, args, avs, &.{}, i, q, note, origin, xfail, false);
    }

    /// `deep`: a send's demand (§23.2), on every cell at or below `q`; one
    /// on no cell gives nothing up and is no line.
    fn callSiteDemandDeep(w: *Walker, inst: Inst.Index, op: []const u8, args: []const Inst.Index, avs: []const AV, callee_av: AV, i: u32, q: u32, note: []const u8, origin: Origin, xfail: ?Rely, deep: bool) Allocator.Error!void {
        const at = try w.projPath(avs[i], q, null);
        const base = if (deep) try w.flat(at) else at;
        if (deep and base.len == 0) return;
        var others: std.ArrayList(AV) = .empty;
        try others.append(w.a, callee_av);
        for (avs, 0..) |av, x| if (x != i) try others.append(w.a, av);
        var rest: std.ArrayList(Entry) = .empty;
        for (avs[i]) |e| if (!w.o.overlap(e.path, q)) try rest.append(w.a, e);
        try others.append(w.a, rest.items);
        const arena = w.o.out.allocator();
        const text = if (w.mode == .report) try w.baseText(args[i]) else "";
        const base_text = if (q == eps or w.mode != .report) text else try std.fmt.allocPrint(arena, "{s}{s}", .{ text, try w.o.pathText(q) });
        const ref = try w.refPath(args[i]);
        try w.demandOn(.{
            .kind = .callsite,
            .token = w.token(inst),
            .op = op,
            .base_text = base_text,
            .base_ref = if (ref) |r| .{ .local = r.local, .path = try w.o.concat(r.path, q) } else null,
            .base_ty = if (q == eps and !deep) w.instType(args[i]) else null,
            .base = base,
            .others = others.items,
            .note = note,
            .origin = origin,
            .xfail = xfail,
            .deep = deep,
            .base_inst = if (q == eps) args[i] else null,
        });
    }

    /// A probe (§16.4 item 4): whether `av`'s cells pass the four conditions
    /// at this point; resolved with the demands, printed by none.
    /// §18.8: a demand a once closure makes — its creation on the captures
    /// it writes (`creation`), or a call on its own cell (`probe`) — resolved
    /// with the probes, and read back where its writes are decided.
    fn onceDemand(w: *Walker, kind: DemandKind, tok: u32, base: AV, base_ref: ?Capture, ci: u32) Allocator.Error!u32 {
        return w.onceDemandDeep(kind, tok, base, base_ref, ci, false);
    }

    fn onceDemandDeep(w: *Walker, kind: DemandKind, tok: u32, base: AV, base_ref: ?Capture, ci: u32, deep: bool) Allocator.Error!u32 {
        const idx: u32 = @intCast(w.probe_ok.items.len);
        try w.probe_ok.append(w.a, false);
        try w.probe_approx.append(w.a, false);
        try w.probe_info.append(w.a, null);
        try w.demandOn(.{
            .kind = kind,
            .token = tok,
            .op = "",
            .base_text = "",
            .base_ref = base_ref,
            .base_ty = null,
            .base = base,
            .others = &.{},
            .probe = idx,
            .closures = true,
            .creation_ci = if (kind == .creation) ci else none,
            .deep = deep,
        });
        return idx;
    }

    /// Every cell `av` holds, closures expanded, at ε: what a send gives up
    /// (§23.2), as a probe's base is (§16.4 item 4).
    fn flat(w: *Walker, av: AV) Allocator.Error!AV {
        var base: std.ArrayList(Entry) = .empty;
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try base.append(w.a, .{ .path = eps, .cell = e.cell, .approx = e.approx });
        }
        return w.norm(base.items);
    }

    fn probeDemand(w: *Walker, inst: Inst.Index, av: AV, others: []const AV) Allocator.Error!u32 {
        const idx: u32 = @intCast(w.probe_ok.items.len);
        try w.probe_ok.append(w.a, false);
        try w.probe_approx.append(w.a, false);
        try w.probe_info.append(w.a, null);
        var base: std.ArrayList(Entry) = .empty;
        for (try w.expand(av)) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .closure or k == .func) continue;
            try base.append(w.a, .{ .path = eps, .cell = e.cell, .approx = e.approx });
        }
        try w.demandOn(.{
            .kind = .probe,
            .token = w.token(inst),
            .op = "",
            .base_text = "",
            .base_ref = null,
            .base_ty = null,
            .base = base.items,
            .others = others,
            .probe = idx,
        });
        return idx;
    }

    /// A function value's line (§16.5, §16.11).
    fn valueLine(w: *Walker, tok: u32, name: []const u8, verdict: Verdict, detail: []const u8, note: []const u8, assumed: bool) Allocator.Error!void {
        try w.demands.append(w.a, .{
            .kind = .value,
            .token = tok,
            .op = "value",
            .base = name,
            .base_local = none,
            .base_path = eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .callback_param,
            .holders = &.{},
            .fixed = .{ .verdict = verdict, .detail = detail, .assumed = assumed },
            .note = note,
        });
    }

    fn firstUnseen(w: *Walker, t: Target) Allocator.Error!bool {
        const gop = try w.unseen_funcs.getOrPut(w.a, (@as(u64, t.m) << 32) | t.d);
        return !gop.found_existing;
    }

    const Sight = union(enum) {
        /// The value leaves the walk's sight (§16.5).
        pending: []const u8,
        /// It is handed to a callee with no summary (§15 decision 2).
        no_summary: []const u8,
    };

    /// Every writing function value in `av` that goes where the walk cannot
    /// see its calls, and every function parameter that does (§16.5).
    fn sight(w: *Walker, av: AV, why: Sight, tok: u32) Allocator.Error!void {
        try w.sightAt(av, why, tok, 0);
    }

    fn sightAt(w: *Walker, av: AV, why: Sight, tok: u32, depth: u32) Allocator.Error!void {
        // Each `◇` hop goes to a local of a strictly enclosing frame, so the
        // chain ends within the frames; the bound only guards that.
        if (depth > w.frames.items.len) return;
        for (av) |e| {
            const c = w.cells.items[e.cell];
            switch (c.kind) {
                .closure => {
                    // Its calls of the declaration's function parameters go
                    // out of sight with it (§18.9).
                    for (w.env_calls.items) |ec| if (ec.closure == c.a) {
                        w.fn_state.items[ec.j].seen = false;
                    };
                    const cl = &w.closures.items[c.a];
                    const cls = cl.class orelse continue;
                    if (!cls.writesAny()) continue;
                    try cl.consumed.append(w.a, switch (why) {
                        .pending => |t| .{ .kind = .pending, .why = t },
                        .no_summary => |n| .{ .kind = .no_summary, .name = n },
                    });
                },
                .func => {
                    const t: Target = .{ .m = c.a, .d = c.b };
                    const s = (try w.o.ensureSummary(t.m, t.d)) orelse continue;
                    if (!s.writesAny()) continue;
                    switch (why) {
                        .pending => |t2| if (try w.firstUnseen(t)) try w.valueLine(tok, try w.qualified(t), .pending, t2, "", false),
                        .no_summary => |n| try w.valueLine(tok, try w.qualified(t), .{ .accepted = .callback_param }, "", try std.fmt.allocPrint(w.o.out.allocator(), "no summary: {s}", .{n}), true),
                    }
                },
                .param => {
                    if (c.b != 0 or c.path != eps) continue;
                    // One handed to a send position is kept by the value the
                    // position makes, and its row says what the runtime does
                    // with it there (§23.3).
                    for (w.params, 0..) |p, i| if (p.int() == c.a and w.fn_state.items[i].is_fn and w.fn_state.items[i].send == none) {
                        w.fn_state.items[i].seen = false;
                    };
                },
                .env => {
                    const held = w.local_av[c.a] orelse continue;
                    try w.sightAt(try w.projPath(held, c.path, null), why, tok, depth + 1);
                },
                else => {},
            }
        }
    }

    // ---- function slots and carried lambdas (§24.9) ----------------------

    /// Whether callee `s`'s function parameter or slot `j` has an actual
    /// among `n` arguments.
    fn hasActual(s: *const Summary, n: usize, j: u32) bool {
        if (j < s.params) return j < n;
        const k = j - s.params;
        return k < s.slots.len and s.slots[k][0] < n;
    }

    /// The value callee `s` calls as its function parameter or slot `j`:
    /// the argument, or the function stored in it at the slot's path.
    fn actualOf(w: *Walker, s: *const Summary, avs: []const AV, j: u32) Allocator.Error!?AV {
        if (!hasActual(s, avs.len, j)) return null;
        if (j < s.params) return avs[j];
        const slot = s.slots[j - s.params];
        return try w.projPath(avs[slot[0]], slot[1], null);
    }

    /// The declaration's function slot a value is (§24.9): a function stored
    /// at a path of one of its own parameters, numbered after them on first
    /// sight. Only in the declaration's own frame, and not in a recursive
    /// group, whose rounds would number the slots apart.
    fn slotOf(w: *Walker, av: AV) Allocator.Error!?u32 {
        if (w.frame != 0 or w.recursive) return null;
        var found: ?Cell = null;
        for (av) |e| {
            if (w.o.firstStep(e.path)) |s| if (s.kind == .env) continue;
            if (e.path != eps or found != null) return null;
            found = w.cells.items[e.cell];
        }
        const c = found orelse return null;
        if (c.kind != .param or c.b != 0 or c.path == eps) return null;
        const pi = w.paramIndex(c, 0, w.params) orelse return null;
        for (w.slot_keys.items, 0..) |key, k| if (key[0] == pi and key[1] == c.path) return @intCast(w.params.len + k);
        try w.slot_keys.append(w.a, .{ pi, c.path });
        try w.fn_state.append(w.a, .{ .is_fn = true });
        return @intCast(w.fn_state.items.len - 1);
    }

    /// A lambda a callee's result carries (`ctx.s.klasses[p.a]`, §24.9), as a
    /// closure of this body: its captures hold what the callee's bindings
    /// say, instantiated at this call, and the function values its calls of
    /// the callee's parameters go to leave sight here — the checker does not
    /// see what the lambda hands them.
    fn carry(w: *Walker, p: Prov, ctx: InstCtx) Allocator.Error!AV {
        if (p.a >= ctx.s.klasses.len) return w.single(.{ .kind = .top, .a = 0 });
        const k = ctx.s.klasses[p.a];
        var inner = ctx;
        inner.closure = none;
        const binds = try w.a.alloc(Closure.SynBind, k.binds.len);
        for (binds, k.binds) |*b, kb| {
            var parts: std.ArrayList(AV) = .empty;
            for (kb.provs) |r| {
                var av = try w.under(try w.instProv(r.prov, inner), r.path);
                if (r.approx) av = try w.approxAll(av, ctx.inst);
                try parts.append(w.a, av);
            }
            b.* = .{ .local = kb.local, .path = kb.path, .av = try w.unionOf(parts.items) };
        }
        const cbs = try w.a.alloc(Closure.SynCall, k.cb_js.len);
        for (cbs, k.cb_js) |*c, j| {
            c.* = .{ .j = j, .av = try w.instProv(.{ .kind = .param, .a = j }, inner) };
            if (ctx.effects) try w.sight(c.av, .{ .pending = "a function value a callee returned calls it" }, w.token(ctx.inst));
        }
        try w.closures.append(w.a, .{ .captures = &.{}, .class = k.sum, .binds = binds, .cb_avs = cbs, .carried = true });
        return w.single(.{ .kind = .closure, .a = @intCast(w.closures.items.len - 1) });
    }

    /// The lambda `ci` as the declaration's result may carry it (§24.9): its
    /// class, and its captures in the declaration's vocabulary. Null when a
    /// caller would need more than its result and its reads — it writes,
    /// escapes, relies on exclusive contents, or runs once — or when one of
    /// its captures holds a function value, which has no provenance.
    fn carried(w: *Walker, ci: u32, params: []const Inst.Index, fresh: []const u32) Allocator.Error!?Carried {
        const cl = w.closures.items[ci];
        if (cl.carried) return null;
        const cls = cl.class orelse return null;
        if (cls.limit != .none or cls.once or cls.writesAny() or cls.xreq.len != 0 or cl.env_escapes.len != 0 or cl.env_writes.len != 0) return null;
        for (cls.uses) |u| if (u.bits & (bit_e | bit_j | bit_w) != 0) return null;
        const keep = w.o.keep.allocator();
        var binds: std.ArrayList(Carried.Bind) = .empty;
        for (cl.captures) |cap| {
            const held = w.local_av[cap.local] orelse continue;
            var provs: std.ArrayList(ResEntry) = .empty;
            for (try w.expand(try w.projPath(held, cap.path, null))) |e| {
                const kind = w.cells.items[e.cell].kind;
                if (kind == .closure or kind == .func) return null;
                var prov = (try w.provOf(e.cell, 0, params, fresh)) orelse return null;
                prov.taken = false;
                try provs.append(keep, .{ .path = e.path, .prov = prov, .approx = e.approx != 0 });
            }
            try binds.append(keep, .{ .local = cap.local, .path = cap.path, .provs = provs.items });
        }
        var cb_js: std.ArrayList(u32) = .empty;
        for (w.env_calls.items) |ec| {
            if (ec.closure != ci or ec.j >= params.len) continue;
            if (std.mem.indexOfScalar(u32, cb_js.items, ec.j) == null) try cb_js.append(keep, ec.j);
        }
        const sum = try keep.create(Summary);
        sum.* = cls.*;
        return .{ .sum = sum, .binds = binds.items, .cb_js = cb_js.items };
    }

    /// What a carried lambda's capture `p` holds (§24.9).
    fn carriedEnv(w: *Walker, ci: u32, p: Prov) Allocator.Error!AV {
        for (w.closures.items[ci].binds) |b| {
            if (b.local != p.a or !w.o.isPrefix(b.path, p.path)) continue;
            const rest = (try w.o.suffix(b.path, p.path)) orelse eps;
            return w.projPath(b.av, rest, null);
        }
        return w.single(.{ .kind = .top, .a = 0 });
    }

    /// The actual for function parameter `j` of a callee with a summary,
    /// checked against what the callee supplies it (§16.4 item 4).
    fn checkCallback(w: *Walker, inst: Inst.Index, callee: Callee, args: []const Inst.Index, avs: []const AV, j: u32) Allocator.Error!void {
        const s = callee.sum;
        const ff = s.funOf(j) orelse return;
        const actual = (try w.actualOf(s, avs, j)) orelse return;
        // A function slot (§24.9) has no argument of its own: what the
        // checks below read off an argument's text or type, they skip.
        if (j >= args.len or j >= s.params) return w.checkSlot(inst, s, avs, j, ff, actual, callee.name);
        // The caller's own function parameter, passed on.
        if (w.fnParamOf(actual)) |jj| {
            if (w.frame != 0) {
                w.fn_state.items[jj].seen = false;
                return;
            }
            return w.passOn(inst, s, avs, j, ff, jj);
        }
        const ictx: InstCtx = .{ .inst = inst, .s = s, .avs = avs, .closure = callee.closure, .depth = 0 };
        const classes = try w.classesOf(actual);
        try w.checkClasses(inst, callee, args, avs, j, ff, actual, ictx, classes);
    }

    /// §24.9: a callee's function slot — a function it calls that is stored
    /// at a path of an argument. The caller's own parameter or slot there is
    /// passed on; a function value the caller wrote went through `sight`
    /// where it was stored, so what remains is what the callee does with
    /// what it returns (`need`).
    fn checkSlot(w: *Walker, inst: Inst.Index, s: *const Summary, avs: []const AV, j: u32, ff: FunFacts, actual: AV, callee: []const u8) Allocator.Error!void {
        if (w.frame == 0) if (w.fnParamOf(actual) orelse try w.slotOf(actual)) |jj| return w.passOn(inst, s, avs, j, ff, jj);
        if (!ff.need) return;
        const ictx: InstCtx = .{ .inst = inst, .s = s, .avs = avs, .depth = 0 };
        const classes = try w.classesOf(actual);
        // A slot has no argument of its own to name: the line's base is the
        // function value at the slot's path.
        if (classes.len == 0) return w.needUnknown(inst, "<function value>", callee);
        var reported = false;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse {
                // One line per call, however many classes it cannot place.
                if (!reported) try w.needUnknown(inst, "<function value>", callee);
                reported = true;
                continue;
            };
            if (try w.returnsOwned(c, s, avs, ictx, j, 0, none)) continue;
            const name: []const u8 = switch (cls) {
                .closure => "<lambda>",
                .func => |t| try w.qualified(t),
                .send => "send",
            };
            try w.valueLine(w.token(inst), name, .{ .rejected = .need }, try std.fmt.allocPrint(w.o.out.allocator(), "{s} edits what it returns, which may be a list it does not own", .{callee}), "", false);
        }
    }

    /// A callee that edits what a function it is handed returns (`need`),
    /// handed a function whose class the checker does not know — read out of
    /// a `Ref`, from JavaScript, out of a structure: nothing shows it returns
    /// a list it owns, so the edit is rejected, approximately — the limit is
    /// the checker's, not sharing the text shows.
    fn needUnknown(w: *Walker, inst: Inst.Index, base: []const u8, callee: []const u8) Allocator.Error!void {
        const why = try std.fmt.allocPrint(w.o.out.allocator(), "{s} edits what it returns, and the checker does not know which function it is, so not that it returns a list it owns", .{callee});
        try w.demands.append(w.a, .{
            .kind = .value,
            .token = w.token(inst),
            .op = "value",
            .base = base,
            .base_local = none,
            .base_path = eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .callback_param,
            .holders = &.{},
            .fixed = .{ .verdict = .{ .rejected = .need }, .detail = why },
            .prelim = .{ .cause = .need, .detail = why, .approx = true },
        });
    }

    /// The caller's own function parameter or slot `jj`, handed to the
    /// callee's function parameter or slot `j`: it takes the callee's facts
    /// (§16.4 item 4).
    fn passOn(w: *Walker, inst: Inst.Index, s: *const Summary, avs: []const AV, j: u32, ff: FunFacts, jj: u32) Allocator.Error!void {
        {
            const st = &w.fn_state.items[jj];
            // §23.3: a function parameter handed on to a send position.
            if (ff.send != none and st.send == none) st.send = ff.send;
            st.calls = @fromBackingInt(@min(2, @as(u8, @backingInt(st.calls)) + @as(u8, @backingInt(ff.calls))));
            if (w.recursive and ff.calls != .zero) st.calls = .many;
            st.need = st.need or ff.need;
            st.seen = st.seen and ff.seen;
            const ictx: InstCtx = .{ .inst = inst, .s = s, .avs = avs, .depth = 0 };
            for (s.supply) |e| {
                if (e.fun != j) continue;
                const cells = try w.instProv(e.prov, ictx);
                // Disjoint against every argument but the function and the
                // one the supplied cells come from.
                const from: u32 = if (e.prov.kind == .param) e.prov.a else none;
                var others: std.ArrayList(AV) = .empty;
                for (avs, 0..) |x, i| if (i != j and i != from) try others.append(w.a, x);
                const probe = if (e.owned and cells.len > 0) try w.probeDemand(inst, cells, others.items) else none;
                try w.supplies.append(w.a, .{ .fun = jj, .k = e.k, .path = e.path, .av = cells, .probe = probe, .owned = e.owned, .approx = e.approx, .cond = try w.instXSum(e.xc, ictx), .taken = e.prov.taken });
            }
        }
    }

    /// The actual for the callee's function parameter `j`, a value whose
    /// classes are `classes`, checked against what the callee supplies it
    /// (§16.4 item 4).
    fn checkClasses(w: *Walker, inst: Inst.Index, callee: Callee, args: []const Inst.Index, avs: []const AV, j: u32, facts: FunFacts, actual: AV, ictx: InstCtx, classes: []const Class) Allocator.Error!void {
        var ff = facts;
        if (w.instType(args[j])) |ft| switch (w.store.resolvedContent(ft)) {
            .structure => |st| if (st == .func) {
                ff.need = ff.need and try w.o.tracked(w.store, st.func.result, 0);
            },
            else => {},
        };
        const s = callee.sum;
        const tok = w.token(inst);
        const arena = w.o.out.allocator();
        // §23.4: what is handed a send must be seen to send only what it owns.
        if (ff.send != none) try w.checkSender(inst, callee, args[j], classes, ff.send);
        // §23.5: a constructor handed as a tagger returns what it is given.
        if (ff.need) if (try w.ctorClass(args[j])) |c| {
            if (!try w.returnsOwned(c, s, avs, ictx, j, 0, none)) {
                // Approximate when only an approximate step made it so: a
                // value from JavaScript, a conservative call's result.
                const approx = blk: {
                    const previous = w.ro_exact;
                    w.ro_exact = true;
                    defer w.ro_exact = previous;
                    break :blk try w.returnsOwned(c, s, avs, ictx, j, 0, none);
                };
                const why = if (approx)
                    try std.fmt.allocPrint(arena, "{s} sends what it returns, and it returns what {s} hands it, which may hold a list the checker cannot place — from JavaScript, or through a call it does not see into (§23.5)", .{ callee.name, callee.name })
                else
                    try std.fmt.allocPrint(arena, "{s} sends what it returns, and it returns what {s} hands it, which may be a list the sender still holds (§23.5)", .{ callee.name, callee.name });
                try w.demands.append(w.a, .{
                    .kind = .value,
                    .token = tok,
                    .op = "value",
                    .base = try w.baseText(args[j]),
                    .base_local = none,
                    .base_path = eps,
                    .point = w.point,
                    .frame = w.frame,
                    .ctx = w.ctx,
                    .element = false,
                    .accept = .callback_param,
                    .holders = &.{},
                    .fixed = .{ .verdict = .{ .rejected = .need }, .detail = why },
                    .prelim = .{ .cause = .need, .detail = why, .approx = approx },
                });
            }
            return;
        } else if (classes.len == 0) try w.needUnknown(inst, try w.baseText(args[j]), callee.name);
        var reported = false;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse {
                // One line per call, however many classes it cannot place.
                if (ff.need and !reported) try w.needUnknown(inst, try w.baseText(args[j]), callee.name);
                reported = true;
                continue;
            };
            const name: []const u8 = switch (cls) {
                .closure => "<lambda>",
                .func => |t| try w.qualified(t),
                .send => "send",
            };
            if (cls == .closure) try w.applyEnvCalls(cls.closure, s, j, ictx);
            // §18.8: a once closure goes only where it runs at most once, and
            // handing it on is a call of it.
            if (cls == .closure and c.once and ff.seen) {
                const cl = &w.closures.items[cls.closure];
                if (ff.calls == .many) {
                    if (cl.once_bad == null) cl.once_bad = try std.fmt.allocPrint(arena, "it is handed to {s}, which may call it more than once", .{callee.name});
                } else try w.onceCall(cls.closure, actual, tok);
            }
            const writes = c.writesAny();
            if (!ff.seen) {
                // Need does not depend on seen: retained captures must be
                // empty at callers, and all other results must be owned.
                if (ff.need and !try w.taggerReturnsOwned(c, s, avs, j, cls, ictx))
                    try w.valueLine(tok, name, .{ .rejected = .need }, try std.fmt.allocPrint(arena, "{s} edits what it returns, which may be a list it does not own", .{callee.name}), "", w.frame != 0);
                if (writes) switch (cls) {
                    .closure => |ci| try w.closures.items[ci].consumed.append(w.a, .{ .kind = .pending, .why = try std.fmt.allocPrint(arena, "{s} loses sight of what calls it", .{callee.name}) }),
                    .func => try w.valueLine(tok, name, .pending, try std.fmt.allocPrint(arena, "{s} loses sight of what calls it", .{callee.name}), "", false),
                    // §23.4: a send handed where its calls are not seen
                    // sends what the checker cannot see, when what it sends
                    // may hold a list.
                    .send => if (w.instType(args[j])) |sty| if (funcParam(w.store, sty, 0)) |mty| if (try w.o.holdsList(w.store, mty, 0)) {
                        const why = try std.fmt.allocPrint(arena, "{s} loses sight of the send it is handed, so the checker cannot see what is sent", .{callee.name});
                        try w.demands.append(w.a, .{
                            .kind = .value,
                            .token = tok,
                            .op = "send",
                            .base = callee.name,
                            .base_local = none,
                            .base_path = eps,
                            .point = w.point,
                            .frame = w.frame,
                            .ctx = w.ctx,
                            .element = false,
                            .accept = .callback_param,
                            .holders = &.{},
                            .fixed = .{ .verdict = .{ .rejected = .supply }, .detail = why },
                            .prelim = .{ .cause = .supply, .detail = why, .approx = true },
                        });
                    },
                };
                continue;
            }
            // The supply edge, per parameter of the callback.
            const bad = try w.a.alloc(?[]const u8, c.params);
            @memset(bad, null);
            const bad_approx = try w.a.alloc(bool, c.params);
            @memset(bad_approx, false);
            const bad_cause = try w.a.alloc(Cause, c.params);
            @memset(bad_cause, .supply);
            for (c.uses) |u| {
                if (u.bits & bit_w == 0 or u.param >= c.params) continue;
                for (s.supply) |e| {
                    if (e.fun != j or e.k != u.param or !w.o.overlap(e.path, u.path)) continue;
                    // The path the callback writes, within what the supply holds.
                    const written = (try w.o.suffix(e.path, u.path)) orelse eps;
                    // A returned destructive loan must also be dead in the
                    // caller for the lifetime of the feedback result (§29).
                    if (e.owned and e.prov.kind == .cb) {
                        try w.callbackLoanDemands(inst, callee, args, avs, e.prov.a, written, 0);
                    }
                    const owned = e.owned and try w.provOwned(e.prov, s, avs, ictx, none, 0, written);
                    if (!owned) {
                        // The first reason, unless a later one is exact and
                        // it was not: an exact reason labels the rejection.
                        if (bad[u.param] == null or (bad_approx[u.param] and !(!e.owned and e.approx))) {
                            bad[u.param] = if (cls == .send)
                                try std.fmt.allocPrint(arena, "{s} sends what it may still hold ({s}), and a send gives its payload up (§23.2)", .{ callee.name, try w.o.provText(e.prov) })
                            else if (e.prov.kind == .cb and e.owned)
                                try std.fmt.allocPrint(arena, "{s} hands its parameter {d} what the callback returned before, which may be a list the callback does not own", .{ callee.name, u.param + 1 })
                            else
                                try std.fmt.allocPrint(arena, "{s} supplies its parameter {d} borrowed ({s})", .{ callee.name, u.param + 1, try w.o.provText(e.prov) });
                            // An element's borrowed supply is the checker's
                            // limit (§16.8); a parameter's or a callback's
                            // result is what the text shows.
                            bad_approx[u.param] = !e.owned and e.approx;
                            bad_cause[u.param] = .supply;
                        }
                        continue;
                    }
                    // A destructive supply written: its container must be
                    // exclusive, so that no other position sees the write
                    // (§18.5).
                    var supply_cond = try w.instXSum(e.xc, ictx);
                    // A dictionary focus may require only the written array's
                    // own exclusivity. This does not authorise a deep write.
                    if (!s.coarse and !c.coarse and s.limit == .none and c.limit == .none and e.prov.taken and u.bits & bit_d == 0 and e.prov.kind == .param and try w.o.dictTreePath(e.prov.path)) {
                        const tail = (try w.o.suffix(e.path, u.path)) orelse eps;
                        var p = e.prov;
                        p.path = try w.o.concat(p.path, tail);
                        const scoped = try w.spineCond(try w.instProv(p, ictx));
                        if (scoped != cond_lost and scoped != cond_shared) {
                            const usable = for (w.conds.items[scoped].atoms) |atom| {
                                if (!w.ownedBy(atom, w.frame)) break false;
                            } else true;
                            if (usable) supply_cond = scoped;
                        }
                    }
                    if (e.prov.taken) switch (try w.rely(supply_cond, w.frame)) {
                        .ok => {},
                        else => |r| if (bad[u.param] == null) {
                            bad[u.param] = try w.sharesText(callee.name, u.param, e, args);
                            bad_approx[u.param] = r == .approx;
                            bad_cause[u.param] = .exclusive;
                        },
                    };
                    // An owned supply of the callee's own parameter: the
                    // caller's argument is written, at the call.
                    if (e.prov.kind == .param and e.prov.a < args.len) {
                        var path = e.prov.path;
                        if (try w.o.suffix(e.path, u.path)) |rest| path = try w.o.concat(path, rest);
                        const note = if (w.mode != .report) "" else try std.fmt.allocPrint(arena, "{s} writes what {s} supplies it", .{ name, callee.name });
                        try w.callSiteDemandDeep(inst, callee.op, args, avs, if (callee.closure != none) try w.single(.{ .kind = .closure, .a = callee.closure }) else &.{}, e.prov.a, path, note, if (s.limit != .none or c.limit != .none) .limit else if (u.bits & bit_x == 0) .approx else .exact, null, u.bits & bit_d != 0);
                    }
                }
            }
            // What the callback relied on (§18.4 item 2), against what the
            // callee supplies it and what it captured.
            for (c.xreq) |x| {
                const r = try w.rely(try w.classReq(x, s, j, cls, ictx), w.frame);
                if (r == .ok) continue;
                const k = xreqParam(x) orelse 0;
                if (k >= c.params or bad[k] != null) continue;
                bad[k] = try std.fmt.allocPrint(arena, "it needs what {s} supplies it not to share, and it may", .{callee.name});
                bad_approx[k] = r == .approx;
                bad_cause[k] = .exclusive;
            }
            // The callee edits what the callback returns (§16.2's need).
            var need_bad = false;
            if (ff.need and !try w.returnsOwned(c, s, avs, ictx, j, 0, none)) need_bad = true;
            switch (cls) {
                .send => if (bad[0]) |why| try w.demands.append(w.a, .{
                    .kind = .value,
                    .token = tok,
                    .op = "send",
                    .base = callee.name,
                    .base_local = none,
                    .base_path = eps,
                    .point = w.point,
                    .frame = w.frame,
                    .ctx = w.ctx,
                    .element = false,
                    .accept = .callback_param,
                    .holders = &.{},
                    .fixed = .{ .verdict = .{ .rejected = bad_cause[0] }, .detail = why },
                    .prelim = .{ .cause = bad_cause[0], .detail = why, .approx = bad_approx[0] },
                }),
                .closure => |ci| {
                    try w.closures.items[ci].consumed.append(w.a, .{ .kind = .supply, .bad = bad, .bad_approx = bad_approx, .bad_cause = bad_cause, .name = callee.name });
                    if (need_bad) try w.valueLine(tok, name, .{ .rejected = .need }, try std.fmt.allocPrint(arena, "{s} edits what it returns, which may be a list it does not own", .{callee.name}), "", false);
                },
                .func => {
                    if (need_bad) {
                        try w.valueLine(tok, name, .{ .rejected = .need }, try std.fmt.allocPrint(arena, "{s} edits what it returns, which may be a list it does not own", .{callee.name}), "", false);
                    } else if (writes) {
                        var first: ?usize = null;
                        for (bad, 0..) |x, k| if (x != null and first == null) {
                            first = k;
                        };
                        if (first) |k| {
                            try w.demands.append(w.a, .{
                                .kind = .value,
                                .token = tok,
                                .op = "value",
                                .base = name,
                                .base_local = none,
                                .base_path = eps,
                                .point = w.point,
                                .frame = w.frame,
                                .ctx = w.ctx,
                                .element = false,
                                .accept = .callback_param,
                                .holders = &.{},
                                .fixed = .{ .verdict = .{ .rejected = bad_cause[k] }, .detail = bad[k].? },
                                .prelim = .{ .cause = bad_cause[k], .detail = bad[k].?, .approx = bad_approx[k] },
                            });
                        } else {
                            try w.valueLine(tok, name, .{ .accepted = .callback_param }, "", try std.fmt.allocPrint(arena, "{s} supplies it owned", .{callee.name}), false);
                        }
                    }
                },
            }
        }
    }

    /// §23.4: the function value `arg`, handed to a position where the
    /// runtime gives it a send as its parameter `k`, must be seen to send
    /// only what it owns. A lambda written there has its sends checked where
    /// they are made; a top-level function's are its summary's supplies to
    /// that parameter; anything else is not followed.
    fn checkSender(w: *Walker, inst: Inst.Index, callee: Callee, arg: Inst.Index, classes: []const Class, k: u32) Allocator.Error!void {
        const arena = w.o.out.allocator();
        // A message type that holds no cell has nothing to give up.
        const fty = w.instType(arg) orelse return;
        const sty = funcParam(w.store, fty, k) orelse return;
        const mty = funcParam(w.store, sty, 0) orelse return;
        if (!try w.o.holdsList(w.store, mty, 0)) return;
        const tok = w.token(inst);
        var why: ?[]const u8 = null;
        var approx = true;
        if (classes.len == 0) why = try std.fmt.allocPrint(arena, "the checker does not know which function {s} is handed here, so it cannot see what it sends", .{callee.name});
        for (classes) |cls| switch (cls) {
            .send => {},
            .closure => |ci| {
                const ps = w.closures.items[ci].params;
                if (k < ps.len and w.instCol(bool, w.send_params, ps[k].int(), false)) continue;
                if (why == null) why = "a function value written apart from where it is handed a send: the checker follows the sends of a lambda written at the send position, or of a top-level function";
            },
            .func => |t| {
                const s = (try w.o.ensureSummary(t.m, t.d)) orelse continue;
                const f = s.funOf(k) orelse continue;
                if (!f.seen) {
                    if (why == null) why = try std.fmt.allocPrint(arena, "{s} hands its send where the checker cannot see its calls", .{try w.qualified(t)});
                    continue;
                }
                for (s.supply) |e| {
                    if (e.fun != k) continue;
                    if (e.owned and e.prov.kind != .param and e.prov.kind != .cb) continue;
                    if (why != null and !approx) continue;
                    why = if (e.owned)
                        try std.fmt.allocPrint(arena, "{s} sends what it was handed ({s}), which {s} does not supply it owned", .{ try w.qualified(t), try w.o.provText(e.prov), callee.name })
                    else
                        try std.fmt.allocPrint(arena, "{s} sends what it may still hold ({s}), and a send gives its payload up (§23.2)", .{ try w.qualified(t), try w.o.provText(e.prov) });
                    approx = e.owned or e.approx;
                }
            },
        };
        const reason = why orelse return;
        try w.demands.append(w.a, .{
            .kind = .value,
            .token = tok,
            .op = "send",
            .base = try w.baseText(arg),
            .base_local = none,
            .base_path = eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .callback_param,
            .holders = &.{},
            .fixed = .{ .verdict = .{ .rejected = .supply }, .detail = reason },
            .prelim = .{ .cause = .supply, .detail = reason, .approx = approx },
        });
    }

    /// §23.5: a constructor handed as a function: it returns its arguments,
    /// each at its own field.
    fn ctorClass(w: *Walker, arg: Inst.Index) Allocator.Error!?*const Summary {
        switch (w.bir.instTag(arg)) {
            .ctor, .ext_ctor => {},
            else => return null,
        }
        const ty = w.instType(arg) orelse return null;
        const ps = switch (w.store.resolvedContent(ty)) {
            .structure => |st| switch (st) {
                .func => |fun| w.store.vars(fun.params),
                else => return null,
            },
            else => return null,
        };
        const c = try w.ctorOf(arg);
        const keep = w.o.keep.allocator();
        var uses: std.ArrayList(UseEntry) = .empty;
        var res: std.ArrayList(ResEntry) = .empty;
        // A field that can hold no list `update` could write carries nothing.
        for (ps, 0..) |pt, i| {
            if (!try w.o.holdsList(w.store, pt, 0)) continue;
            try uses.append(keep, .{ .param = @intCast(i), .path = eps, .bits = bit_a });
            try res.append(keep, .{ .path = try w.o.child(eps, .ctor, c *% 64 +% @as(u32, @intCast(i))), .prov = .{ .kind = .param, .a = @intCast(i), .path = eps } });
        }
        const out = try w.a.create(Summary);
        // A constructor has exactly this primitive row, so unseen callback
        // calls cannot bypass its need check (including a variable-held one).
        out.* = try w.o.normalize(.{ .params = @intCast(ps.len), .uses = uses.items, .res = res.items, .asserted = true });
        return out;
    }

    fn sharesText(w: *Walker, name: []const u8, k: u32, e: SupplyEntry, args: []const Inst.Index) Allocator.Error![]const u8 {
        const arena = w.o.out.allocator();
        if (e.prov.kind == .param and e.prov.a < args.len) {
            return std.fmt.allocPrint(arena, "{s} hands its parameter {d} an element of {s}, whose elements may share one list", .{ name, k + 1, try w.baseText(args[e.prov.a]) });
        }
        return std.fmt.allocPrint(arena, "{s} hands its parameter {d} an element of a list whose elements may share one list", .{ name, k + 1 });
    }

    /// A callback's `xreq` atom, made of what callee `s` supplies it and
    /// what it captured (§18.4 item 2).
    fn classReq(w: *Walker, x: XAtom, s: *const Summary, j: u32, cls: Class, ctx: InstCtx) Allocator.Error!u32 {
        return switch (x.kind) {
            .excl => w.deepCond(try w.classSide(x.a, s, j, cls, ctx)),
            .spine => w.spineCond(try w.classSide(x.a, s, j, cls, ctx)),
            .sep_spine => w.sepSpineValues(try w.classSide(x.a, s, j, cls, ctx), try w.classSide(x.b, s, j, cls, ctx)),
            .sep => w.sepValues(try w.classSide(x.a, s, j, cls, ctx), try w.classSide(x.b, s, j, cls, ctx)),
            .keep, .keep_spine => cond_lost,
        };
    }

    /// One side of a callback's atom: its parameter, as the callee supplies
    /// it; its capture, as held here.
    fn classSide(w: *Walker, p: Prov, s: *const Summary, j: u32, cls: Class, ctx: InstCtx) Allocator.Error!AV {
        switch (p.kind) {
            .param => {
                var parts: std.ArrayList(AV) = .empty;
                for (s.supply) |e| {
                    if (e.fun != j or e.k != p.a or !w.o.overlap(e.path, p.path)) continue;
                    const at = try w.under(try w.instProv(e.prov, ctx), e.path);
                    try parts.append(w.a, try w.projPath(at, p.path, null));
                }
                return w.unionOf(parts.items);
            },
            .env => {
                if (cls != .closure) return w.single(.{ .kind = .top, .a = 0 });
                const held = w.local_av[p.a] orelse return &.{};
                return w.projPath(held, p.path, null);
            },
            else => return w.single(.{ .kind = .top, .a = 0 }),
        }
    }

    /// A callback result that will be written transfers any item loan it
    /// returns. Its input holder must not survive that transfer, and the
    /// existing taken-container condition proves separation of positions.
    fn callbackLoanDemands(w: *Walker, inst: Inst.Index, callee: Callee, args: []const Inst.Index, avs: []const AV, j: u32, written: u32, depth: u32) Allocator.Error!void {
        if (depth >= inst_depth) return;
        const s = callee.sum;
        const actual = (try w.actualOf(s, avs, j)) orelse return;
        for (try w.classesOf(actual)) |cls| {
            const c = (try w.classSummary(cls)) orelse continue;
            for (c.res) |r| {
                if (!w.o.isPrefix(r.path, written) or r.prov.kind != .param) continue;
                for (s.supply) |supply| {
                    if (supply.fun != j or supply.k != r.prov.a or !w.o.overlap(supply.path, r.prov.path)) continue;
                    const p = supply.prov;
                    if (p.kind == .cb and p.a != j) {
                        try w.callbackLoanDemands(inst, callee, args, avs, p.a, written, depth + 1);
                    }
                    if (!p.taken or p.kind != .param or p.a >= args.len) continue;
                    var path = p.path;
                    if (try w.o.suffix(supply.path, r.prov.path)) |rest| path = try w.o.concat(path, rest);
                    if (try w.o.suffix(r.path, written)) |rest| path = try w.o.concat(path, rest);
                    try w.callSiteDemandDeep(inst, callee.op, args, avs, if (callee.closure != none) try w.single(.{ .kind = .closure, .a = callee.closure }) else &.{}, p.a, path, "a returned item is transferred to a later written callback result", if (supply.approx or r.approx) .approx else .exact, null, false);
                }
            }
        }
    }

    /// Whether a supply of provenance `p` is owned once its guard is
    /// decided: a `cb_j′` supply needs the actual for πⱼ′ to return owned,
    /// except while that is the guard being established (`guard`).
    fn provOwned(w: *Walker, p: Prov, s: *const Summary, avs: []const AV, ictx: InstCtx, guard: u32, depth: u32, written: u32) Allocator.Error!bool {
        if (p.kind != .cb) return true;
        if (p.a == guard) return true;
        if (depth >= inst_depth) return false;
        const classes = try w.classesOf((try w.actualOf(s, avs, p.a)) orelse return false);
        if (classes.len == 0) return false;
        for (classes) |cls| {
            const c = (try w.classSummary(cls)) orelse return false;
            if (!try w.returnsOwned(c, s, avs, ictx, p.a, depth + 1, written)) return false;
        }
        return true;
    }

    /// A retained tagger capture is never owned. Symbolic captures may be
    /// required to contain no cell at callers (sep p p); cb self-separation
    /// instead means fresh across calls, so cannot encode that requirement.
    fn taggerReturnsOwned(w: *Walker, c: *const Summary, s: *const Summary, avs: []const AV, j: u32, cls: Class, ictx: InstCtx) Allocator.Error!bool {
        if (try w.returnsOwned(c, s, avs, ictx, j, 0, none)) return true;
        var res: std.ArrayList(ResEntry) = .empty;
        for (c.res) |r| {
            if (r.prov.kind == .cb and r.prov.b == 1) {
                if (r.prov.a >= w.fn_state.items.len) return false;
                // §18.9: retain the actual supplies even when the enclosing
                // tagger calls were unseen (and so formerly counted zero).
                if (cls != .closure or w.frame != 0) return false;
                const params = try w.a.alloc(AV, c.params);
                for (params, 0..) |*pa, k| {
                    var parts: std.ArrayList(AV) = .empty;
                    for (s.supply) |e| {
                        if (e.fun != j or e.k != k) continue;
                        try parts.append(w.a, try w.under(try w.instProv(e.prov, ictx), e.path));
                    }
                    pa.* = try w.unionOf(parts.items);
                }
                try w.applyEnvCalls(cls.closure, null, 0, .{ .inst = ictx.inst, .s = c, .avs = params, .closure = cls.closure, .depth = 0 });
                w.fn_state.items[r.prov.a].need = true;
                // Deferred tagger calls cannot inherit a locally seen
                // call's supply/loan proof; keep the combined protocol unseen.
                w.fn_state.items[r.prov.a].seen = false;
                w.fn_state.items[r.prov.a].calls = .many;
                continue;
            }
            if (r.prov.kind != .env) {
                try res.append(w.a, r);
                continue;
            }
            if (cls != .closure) return false;
            const cl = w.closures.items[cls.closure];
            const captured = if (cl.carried)
                try w.carriedEnv(cls.closure, r.prov)
            else if (w.local_av[r.prov.a]) |held|
                try w.projPath(held, r.prov.path, null)
            else
                return false;
            for (try w.expand(captured)) |e| {
                const cell_kind = w.cells.items[e.cell].kind;
                // expand has already added captured descendants; code itself
                // holds no mutable cell. Each descendant is checked below.
                if (cell_kind == .closure or cell_kind == .func) continue;
                if (cell_kind != .param and cell_kind != .env) return false;
                if (try w.rely(try w.sepCond(e.cell, e.cell), w.frame) != .ok) return false;
            }
        }
        var conditional = c.*;
        conditional.res = res.items;
        return w.returnsOwned(&conditional, s, avs, ictx, j, 0, none);
    }

    /// §16.4 item 5: whether class `c`, called by `s` as its parameter `j`,
    /// returns owned.
    /// Ownership is required at the written roots, not at their contents
    /// (`none`: every path). Aliases of those roots at any result path count.
    fn returnsOwned(w: *Walker, c: *const Summary, s: *const Summary, avs: []const AV, ictx: InstCtx, j: u32, depth: u32, written: u32) Allocator.Error!bool {
        if (c.limit != .none) return false;
        // A coarsened or pessimistic callee's supply rows no longer say
        // where each parameter is supplied: nothing it hands back is owned.
        if (s.coarse or s.limit != .none) return false;
        for (c.res) |r| {
            if (written != none and !w.o.isPrefix(r.path, written)) continue;
            // A list from JavaScript is a limit of the analysis, not sharing
            // the text shows (§8.3, `unknown`).
            if (w.ro_exact and (r.approx or r.prov.kind == .top)) continue;
            switch (r.prov.kind) {
                .fresh => {},
                .param => {
                    for (c.uses) |u| if (u.param == r.prov.a and u.bits & (bit_e | bit_j) != 0 and w.o.overlap(u.path, r.prov.path)) return false;
                    for (s.supply) |e| {
                        if (e.fun != j or e.k != r.prov.a or !w.o.overlap(e.path, r.prov.path)) continue;
                        // §28.5: an approximate supply is a limit, not proven sharing.
                        if (w.ro_exact and e.approx) continue;
                        if (!e.owned) return false;
                        // A taken item is a conditional loan. Returning it
                        // onto a feedback edge retains its source condition.
                        if (e.prov.taken) switch (try w.rely(try w.instXSum(e.xc, ictx), w.frame)) {
                            .ok => {},
                            .exact => return false,
                            .approx => if (!w.ro_exact) return false,
                        };
                        if (!try w.provOwned(e.prov, s, avs, ictx, j, depth, none)) return false;
                    }
                },
                else => return false,
            }
            // One provenance at two distinct result paths is not owned.
            for (c.res) |x| {
                if (x.path != r.path and x.prov.eql(r.prov)) return false;
            }
        }
        return true;
    }

    const Item = struct { inst: Inst.Index, spread: bool };

    /// A list literal with a spread, read back as one construction (§3.2).
    fn construction(w: *Walker, top: Inst.Index) Allocator.Error!AV {
        var items: std.ArrayList(Item) = .empty;
        var cur = top;
        while (true) {
            const args = w.callArgs(cur);
            try items.append(w.a, .{ .inst = args[0], .spread = w.isSpreadAppend(cur) });
            const next = args[1];
            if (w.isSpreadCall(next) and w.balanced(w.token(cur), w.token(next))) {
                cur = next;
                continue;
            }
            if (w.bir.instTag(next) == .list and w.token(next) < w.token(cur)) {
                for (w.bir.extraSlice(Bir.inlineRange(w.bir.instData(next)), Inst.Index)) |el| {
                    try items.append(w.a, .{ .inst = el, .spread = false });
                }
            } else {
                try items.append(w.a, .{ .inst = next, .spread = true });
            }
            break;
        }
        return w.build(top, "construction", items.items);
    }

    /// A `++` chain on lists: one construction whose base is its leftmost
    /// operand (§3.2).
    fn appendChain(w: *Walker, top: Inst.Index) Allocator.Error!AV {
        var items: std.ArrayList(Item) = .empty;
        var cur = top;
        while (true) {
            const args = w.callArgs(cur);
            try items.append(w.a, .{ .inst = args[0], .spread = true });
            if (w.isListAppend(args[1])) {
                cur = args[1];
                continue;
            }
            try items.append(w.a, .{ .inst = args[1], .spread = true });
            break;
        }
        return w.build(top, "++", items.items);
    }

    fn build(w: *Walker, top: Inst.Index, op: []const u8, items: []const Item) Allocator.Error!AV {
        const insts = try w.a.alloc(Inst.Index, items.len);
        for (items, insts) |it, *x| x.* = it.inst;
        const avs = try w.evalOperands(insts, false);
        w.popPending(avs.len);
        try w.consume(insts, w.token(top));
        try w.useTemporaries(insts, avs, w.token(top));
        for (items, avs) |it, av| {
            if (it.spread) continue;
            try w.sight(av, .{ .pending = "it is stored in a list" }, w.token(top));
        }
        var base_at: ?usize = null;
        for (items, 0..) |it, i| if (it.spread) {
            base_at = i;
            break;
        };
        const bi = base_at orelse return w.single(.{ .kind = .site, .a = top.int(), .ty = w.instTypeOpt(top) });
        // A list re-built in the shape a pattern just matched is that list
        // (thesis §3.8): an alias, not a demand.
        if (w.reconsed(items)) return avs[bi];
        // A prepend — items, then the one spread, last — copies its base
        // and writes nothing (§3.2 as amended for slice 3f).
        if (bi > 0 and bi == items.len - 1) return w.prepended(top, insts, avs, bi);
        const others = try w.a.alloc(AV, avs.len - 1);
        var k: usize = 0;
        for (avs, 0..) |av, i| if (i != bi) {
            others[k] = av;
            k += 1;
        };
        const ref = try w.refPath(items[bi].inst);
        try w.demandOn(.{
            .kind = .report,
            .token = w.token(top),
            .op = op,
            .base_text = try w.baseText(items[bi].inst),
            .base_ref = ref,
            .base_ty = w.instType(items[bi].inst),
            .base = avs[bi],
            .others = others,
            .base_inst = items[bi].inst,
        });
        // §18.2: the base's condition, lowered by what is stored in it — a
        // later spread element by element when it is a temporary, and lost
        // when it is a list that lives on.
        var stored: std.ArrayList(AV) = .empty;
        var spread_k = cond_yes;
        for (items, avs, 0..) |it, av, i| {
            if (i == bi) continue;
            if (!it.spread) {
                try stored.append(w.a, av);
            } else if ((try w.refPath(it.inst)) != null) {
                spread_k = cond_lost;
            } else {
                try stored.append(w.a, try w.elementsOf(av));
                spread_k = try w.condAnd(spread_k, try w.deepCond(av));
            }
        }
        const stored_k = try w.condAnd(spread_k, try w.storedCond(stored.items, try w.elementsOf(avs[bi])));
        for (avs[bi]) |e| if (e.path == eps) try w.lowerCond(e.cell, stored_k);
        var parts: std.ArrayList(AV) = .empty;
        try parts.append(w.a, avs[bi]);
        for (items, avs, 0..) |it, av, i| {
            if (i == bi) continue;
            if (it.spread) {
                try parts.append(w.a, try w.shift(try w.elementsOf(av), .{ .kind = .elem, .arg = 0 }));
            } else {
                try parts.append(w.a, try w.shift(av, .{ .kind = .elem, .arg = 0 }));
            }
        }
        return w.unionOf(parts.items);
    }

    /// A prepend, `[ x, …xs ]` (§3.2 as amended for slice 3f): a new array
    /// holding the items and then a copy of the base's elements, so the base
    /// is only read. The result is that new array, or — when the runtime
    /// re-conses onto a view (`backend.md` §4) — a header over the base's
    /// own array: it aliases the base, whose condition it does not lower.
    /// Sound only while the backend never writes a prepend's base in place
    /// (§25.2, *The backend agrees*): `emit/PrependShapes` pins every shape,
    /// and slice 5's in-place lowering must leave prepends as copies.
    fn prepended(w: *Walker, top: Inst.Index, insts: []const Inst.Index, avs: []const AV, bi: usize) Allocator.Error!AV {
        const site = try w.single(.{ .kind = .site, .a = top.int(), .ty = w.instTypeOpt(top) });
        var stored: std.ArrayList(AV) = .empty;
        for (avs[0..bi]) |av| try stored.append(w.a, av);
        const k = try w.condAnd(try w.storedCond(stored.items, try w.elementsOf(avs[bi])), try w.deepCond(avs[bi]));
        try w.initCond(site[0].cell, k);
        var parts: std.ArrayList(AV) = .empty;
        try parts.append(w.a, site);
        // The array may be the base's — only a re-cons makes it so, which
        // the text does not show (§8.4) — while the elements are the base's.
        // Not when the item put in front of the base is a list made after
        // it (§26.3): a re-cons needs that item to be already stored before
        // the base's view, and a new array the base cannot reach is not.
        if (!try w.madeAfter(insts[bi - 1], avs[bi - 1], avs[bi])) try parts.append(w.a, try w.approxAll(avs[bi], top));
        try parts.append(w.a, try w.shift(try w.proj(avs[bi], .{ .kind = .elem, .arg = 0 }, w.listElement(top)), .{ .kind = .elem, .arg = 0 }));
        for (stored.items) |av| try parts.append(w.a, try w.shift(av, .{ .kind = .elem, .arg = 0 }));
        return w.unionOf(parts.items);
    }

    /// §26.3: whether `item`, put in front of a prepend's base, is a list
    /// made after the base — so that no re-cons can answer the base's
    /// array. Core's `cons` re-conses only when the item is `Js.same` as the
    /// element stored before the base's view (or in a trie head's slack),
    /// an element of a list whose array the base shares: one the domain
    /// names at the base's cells (a view is its scrutinee's cells, §5). A
    /// list is compared by identity, and a new array — a literal's, or a
    /// callee's fresh result, exact, never handed to JavaScript — is that
    /// element only if the base reaches it. Anything else may be.
    fn madeAfter(w: *Walker, item: Inst.Index, item_av: AV, base: AV) Allocator.Error!bool {
        if (w.listElement(item) == null) return false;
        var cells: std.ArrayList(Entry) = .empty;
        for (item_av) |e| {
            if (e.path != eps) continue;
            if (e.approx != 0) return false;
            const c = w.cells.items[e.cell];
            switch (c.kind) {
                // A list literal's new array.
                .site => {},
                // A call's result: `b` is the callee's fresh number, made
                // from its summary's `fresh` (`instProv`). `b == 0` is §6.1's
                // assumed fresh cell of a callee with no summary, which may
                // be any argument or a top-level list: not known to be new.
                .result => if (c.b == 0) return false,
                else => return false,
            }
            // Exact (above) and never handed to JavaScript (here), which
            // could store it anywhere, the base's array included.
            if (try w.isEscaped(e.cell)) return false;
            try cells.append(w.a, e);
        }
        if (cells.items.len == 0) return false;
        return (try w.reaches(base, cells.items)) == null;
    }

    /// The element type of a list-typed instruction, when the checker solved it.
    fn listElement(w: *Walker, inst: Inst.Index) ?Var {
        const v = w.instType(inst) orelse return null;
        switch (w.store.resolvedContent(v)) {
            .structure => |s| switch (s) {
                .app => |a| {
                    if (a.type != w.o.in.types.well_known.list) return null;
                    const args = w.store.vars(a.args);
                    return if (args.len == 1) args[0] else null;
                },
                else => return null,
            },
            else => return null,
        }
    }

    /// §20.8: cells two arguments of a constructor place at one folded path —
    /// a node's value and its subtree's values — are kept apart: what is
    /// stored at a representative shares no cell with what is there. One cell
    /// met twice is one arrival's positions, which its own condition covers.
    fn storedBeside(w: *Walker, parts: []const AV) Allocator.Error!void {
        var filled: usize = 0;
        for (parts) |p| if (p.len > 0) {
            filled += 1;
        };
        if (filled < 2) return;
        for (parts, 0..) |p, i| for (parts[i + 1 ..]) |q| for (p) |e| for (q) |f| {
            if (e.path != f.path or e.cell == f.cell) continue;
            const ke = w.cells.items[e.cell].kind;
            const kf = w.cells.items[f.cell].kind;
            if (ke == .closure or ke == .func or kf == .closure or kf == .func) continue;
            const k = try w.sepCells(e.cell, f.cell, e.approx == 0 and f.approx == 0);
            try w.lowerCond(e.cell, k);
            try w.lowerCond(f.cell, k);
            const sk = try w.sepSpines(e.cell, f.cell, e.approx == 0 and f.approx == 0);
            try w.lowerSpine(e.cell, sk);
            try w.lowerSpine(f.cell, sk);
        };
    }

    /// The entries of a list value at its elements, re-rooted.
    fn elementsOf(w: *Walker, av: AV) Allocator.Error!AV {
        return w.proj(av, .{ .kind = .elem, .arg = 0 }, null);
    }

    fn reconsed(w: *Walker, items: []const Item) bool {
        var list: ?Inst.Index = null;
        for (items, 0..) |it, i| {
            if (w.bir.instTag(it.inst) != .local) return false;
            const l = w.bir.instData(it.inst).lhs;
            if (l >= w.pat_site.len) return false;
            const site = w.pat_site[l] orelse return false;
            if (site.index != i or site.spread != it.spread) return false;
            if (list) |x| {
                if (x != site.list) return false;
            } else list = site.list;
        }
        const pl = list orelse return false;
        return w.bir.extraSlice(Bir.inlineRange(w.bir.instData(pl)), Inst.Index).len == items.len;
    }

    // ---- the check (§8) --------------------------------------------------

    /// When a value holding `outer` also holds `inner`, the path from the
    /// one to the other: a symbolic cell stands for every cell under it
    /// (§4.3), so `param(x, ε)` holds `param(x, .items)` at `.items`.
    fn covers(w: *Walker, outer: u32, inner: u32) Allocator.Error!?u32 {
        if (outer == inner) return eps;
        const o = w.cells.items[outer];
        const i = w.cells.items[inner];
        switch (o.kind) {
            .param, .result, .env, .shared, .cbres, .taken, .payload => {},
            else => return null,
        }
        if (o.kind != i.kind or o.a != i.a or o.b != i.b) return null;
        // One place named twice (a definition's made cell, and the same value
        // through another's summary) is one cell.
        if (o.path == i.path) return eps;
        var bo: [k_limit + 1]Step = undefined;
        var bi: [k_limit + 1]Step = undefined;
        const so = w.o.steps(o.path, &bo);
        const si = w.o.steps(i.path, &bi);
        if (so.len >= si.len) return null;
        for (so, si[0..so.len]) |x, y| if (x.kind != y.kind or x.arg != y.arg) return null;
        var at: u32 = eps;
        for (si[so.len..]) |s| at = try w.o.child(at, s.kind, s.arg);
        return at;
    }

    /// Where `av`, closures expanded, holds one of `cells`: the first such
    /// entry, with its path extended to the cell, or null.
    fn reaches(w: *Walker, av: AV, cells: []const Entry) Allocator.Error!?Entry {
        // An exact entry first: an approximate one is reported only when no
        // exact one reaches the cell.
        var found: ?Entry = null;
        for (try w.expand(av)) |e| {
            for (cells) |c| {
                const rest = (try w.covers(e.cell, c.cell)) orelse
                    (if (try w.splitBase(c.cell, none)) |b| (try w.covers(e.cell, b)) orelse continue else continue);
                const hit: Entry = .{ .path = try w.o.concat(e.path, rest), .cell = c.cell, .approx = if (e.approx != 0) e.approx else c.approx };
                if (hit.approx == 0) return hit;
                if (found == null or hit.approx < found.?.approx) found = hit;
            }
        }
        return found;
    }

    const DemandSpec = struct {
        kind: DemandKind,
        token: u32,
        op: []const u8,
        base_text: []const u8,
        base_ref: ?Capture,
        base_ty: ?Var,
        base: AV,
        others: []const AV,
        note: []const u8 = "",
        probe: u32 = none,
        origin: Origin = .exact,
        /// §18.4 item 3: the callee relied on this argument's contents being
        /// exclusive, and they may not be.
        xfail: ?Rely = null,
        /// §18.8: a closure's own cell is demanded (a once closure's call).
        closures: bool = false,
        creation_ci: u32 = none,
        /// §20.6: an entry demand, by its row.
        entry: ?EntryRow = null,
        /// §20.5: the messages a view builds, which may hold the cell: a
        /// payload, not an operand.
        payload_from: AV = &.{},
        /// §23.2: a send's demand, its base already flattened.
        deep: bool = false,
        /// §28.6: the base's instruction, when the source writes it.
        base_inst: ?Inst.Index = null,
    };

    fn demandOn(w: *Walker, spec: DemandSpec) Allocator.Error!void {
        const out = w.o.out.allocator();
        // The base's cells: at ε, and every `⋆` entry that may be the base.
        var cells: std.ArrayList(Entry) = .empty;
        const any = try w.o.child(eps, .any, 0);
        for (spec.base) |e| {
            const k = w.cells.items[e.cell].kind;
            if ((k == .closure and !spec.closures) or k == .func) continue;
            if (e.path == eps) {
                try cells.append(w.a, e);
                continue;
            }
            if (e.path != any) continue;
            const c = w.cells.items[e.cell];
            if (spec.base_ty) |bt| if (c.ty.unwrap()) |ct| if (!try w.o.mayShare(w.store, bt, ct, 0)) continue;
            try cells.append(w.a, e);
        }
        var rec: DemandRec = .{
            .kind = spec.kind,
            .token = spec.token,
            .op = spec.op,
            .base = spec.base_text,
            .base_local = if (spec.base_ref) |r| r.local else none,
            .base_path = if (spec.base_ref) |r| r.path else eps,
            .point = w.point,
            .frame = w.frame,
            .ctx = w.ctx,
            .element = false,
            .accept = .fresh,
            .holders = &.{},
            .cells = cells.items,
            .note = spec.note,
            .probe = spec.probe,
            .creation_ci = spec.creation_ci,
            .origin = spec.origin,
            .entry = spec.entry,
            .deep = spec.deep,
        };
        if (w.mode == .report) {
            rec.span = w.span;
            if (spec.base_inst) |bi| if (w.spanOf(bi)) |s| {
                rec.base_span = s;
            };
        }
        // A probe on nothing passes: nothing is supplied.
        // Known, Unescaped, Captured, in that order across the cells.
        var worst: ?Cause = null;
        var worst_detail: []const u8 = "";
        var worst_approx: ?bool = null;
        var worst_top: ?[3]u32 = null;
        for (cells.items) |e| {
            // A taken element is classified as the element it stands for
            // (§18.5); writing it relies on its container being exclusive.
            const base = try w.takenBase(e.cell);
            const c = w.cells.items[base];
            if (base != e.cell and spec.kind != .probe) switch (try w.rely(try w.cellCond(e.cell), w.frame)) {
                .ok => {},
                else => |r| if (rec.xfail == null or r == .exact) {
                    rec.xfail = r;
                },
            };
            // A taken element is one position, not the list's elements at large.
            if (base == e.cell and try w.o.representative(c.path)) rec.element = true;
            const rank: Accept = switch (c.kind) {
                .param => if (c.b == 1) .callback_param else .param,
                .result, .cbres => .call,
                else => .fresh,
            };
            if (@backingInt(rank) > @backingInt(rec.accept)) rec.accept = rank;
            if (c.kind == .result and c.b == 0 and rec.assumed.len == 0) rec.assumed = try w.callName(@fromBackingInt(c.a));
            var cause: ?Cause = null;
            var detail: []const u8 = "";
            switch (c.kind) {
                .top => if (c.a == 1) {
                    cause = .limit;
                    detail = "it came from a callee whose summary is past the checker's limits";
                } else {
                    cause = .unknown;
                    detail = "the list came from JavaScript";
                },
                .shared => {
                    cause = .top_level;
                    const b = w.o.in.birs[c.a];
                    detail = try std.fmt.allocPrint(out, "{s}.{s} is a top-level value", .{ w.o.in.module_names[c.a], w.o.in.interner.slice(b.symbol(b.decls[c.b].name)) });
                },
                // §23.6: a message's payload is owned — every send gave it
                // up where it was made (§23.2) — so the cell `msg` is no
                // cause; what a view event builds is `payload_from`'s.
                .payload => if (spec.payload_from.len > 0) {
                    cause = .payload;
                    detail = view_event_detail;
                },
                // A write of a capture: the closure is once, and its creation
                // and calls decide the write (§18.8).
                .env => if (spec.kind != .probe and w.frameClosure(w.frame) != null) {
                    rec.once_ci = w.frameClosure(w.frame).?;
                } else {
                    cause = .captured_edit;
                    detail = try std.fmt.allocPrint(out, "{s} is captured, and how often the closure runs is not known", .{w.localName(c.a)});
                },
                else => {},
            }
            // A real escape names itself before §18.6's conservative one.
            const esc = try w.escapeBefore(e.cell);
            if (esc.gen < w.point or esc.js < w.point) if (cause == null or @backingInt(Cause.escaped) < @backingInt(cause.?)) {
                cause = .escaped;
                detail = if (spec.entry != null and esc.gen >= w.point)
                    "a function the runtime calls hands a function value that captured it to JavaScript, which is taken to keep it (§18.6, §20.4)"
                else if (spec.entry != null)
                    "at some message the runtime keeps it: a command or a subscription holds it, or update escapes it (§20.4)"
                else if (esc.gen < w.point)
                    "it was given to JavaScript, or kept by a callee"
                else
                    try std.fmt.allocPrint(out, "a function value that {s} hands to JavaScript captured it, and JavaScript is taken to keep it (§18.6)", .{try w.callName(@fromBackingInt(esc.why - 1))});
            };
            if (cause) |cs| if (worst == null or @backingInt(cs) < @backingInt(worst.?)) {
                worst = cs;
                worst_detail = detail;
                worst_approx = null;
                worst_top = if (cs == .top_level) .{ c.a, c.b, @intFromBool(c.path == eps) } else null;
            };
        }
        rec.top = worst_top;
        if (spec.xfail) |r| {
            rec.xfail = r;
            rec.xdetail = "the callee needs the list's elements not to share, and they may";
        }
        if (worst) |cs| {
            rec.prelim = .{ .cause = cs, .detail = worst_detail, .approx = worst_approx };
            try w.demands.append(w.a, rec);
            return;
        }
        // A walk for a summary needs a line's cells, not its verdict, unless
        // the split may rely on its scrutinee (§18.4 item 4, §18.11).
        if (w.mode != .report and spec.kind != .probe and spec.kind != .creation and
            (rec.base_local == none or rec.base_local >= w.pat_site.len or w.pat_site[rec.base_local] == null))
        {
            try w.demands.append(w.a, rec);
            return;
        }
        // §20.5: a message a view builds from the model may hold the cell.
        if (spec.payload_from.len > 0 and (try w.reaches(spec.payload_from, cells.items)) != null) {
            rec.prelim = .{ .cause = .payload, .detail = view_event_detail, .approx = true };
            try w.demands.append(w.a, rec);
            return;
        }
        // Disjoint: another operand of the demand reaches the cell.
        var approx_hit: u32 = 0;
        for (spec.others) |av| {
            const hit = (try w.reaches(av, cells.items)) orelse continue;
            if (hit.approx != 0) {
                if (approx_hit == 0 or hit.approx < approx_hit) approx_hit = hit.approx;
                continue;
            }
            rec.prelim = .{ .cause = .disjoint, .detail = "another operand of the same operation reaches it" };
            try w.demands.append(w.a, rec);
            return;
        }
        if (approx_hit != 0 and spec.entry != null) {
            // At an entry the other operands are the model's other paths,
            // as update's joined arms leave them (§20.4, §16.4 item 7).
            rec.prelim = .{ .cause = .disjoint, .detail = "another path of the model may hold it after some message: update's arms are joined, so the entry cannot tell them apart (§20.4)", .approx = true };
            try w.demands.append(w.a, rec);
            return;
        }
        if (approx_hit != 0) {
            rec.via = w.token(@fromBackingInt(@intCast(approx_hit - 1)));
            const cp = w.pos(rec.via);
            rec.prelim = .{ .cause = .call, .detail = try std.fmt.allocPrint(out, "another operand may be it, through the call at {d}:{d}", .{ cp.line, cp.col }) };
            try w.demands.append(w.a, rec);
            return;
        }
        // A temporary already evaluated for an enclosing consumer holds it.
        const base_pending = w.frames.items[w.frame].pending_base;
        for (w.pending.items[base_pending..]) |p| {
            if (p.frame != w.frame or p.is_ref) continue;
            const phit = (try w.reaches(p.av, cells.items)) orelse continue;
            // Waiting for a call with a summary, it holds the cell only
            // where that call touches it (§16.4 item 2).
            if (p.consumer) |s| if (!w.touches(s, p.arg, phit.path)) continue;
            const ppos = w.pos(p.token);
            rec.via = p.token;
            // Held for a call with no summary, the temporary is a holder only
            // because the call is assumed to read it (§6.1): a limit.
            rec.prelim = if (phit.approx != 0 or (p.by_call and p.consumer == null))
                .{ .cause = .call, .detail = try std.fmt.allocPrint(out, "the argument at {d}:{d}, evaluated before it, holds it, and the call it waits for may read it", .{ ppos.line, ppos.col }) }
            else
                .{ .cause = .held_operand, .detail = try std.fmt.allocPrint(out, "the value at {d}:{d}, evaluated before it, holds it until its consumer runs", .{ ppos.line, ppos.col }) };
            try w.demands.append(w.a, rec);
            return;
        }
        // The holders, resolved against later uses once the walk is done.
        var holders: std.ArrayList(Holder) = .empty;
        for (w.local_av, 0..) |maybe, l| {
            const av = maybe orelse continue;
            if (w.local_frame[l] != w.frame) continue;
            if (!w.compatible(w.local_ctx[l], w.ctx)) continue;
            for (try w.expand(av)) |e| {
                for (cells.items) |c| {
                    var split = false;
                    const rest = (try w.covers(e.cell, c.cell)) orelse blk: {
                        const b = (try w.splitBase(c.cell, @intCast(l))) orelse continue;
                        split = true;
                        break :blk (try w.covers(e.cell, b)) orelse continue;
                    };
                    try holders.append(w.a, .{
                        .local = @intCast(l),
                        .path = try w.o.concat(e.path, rest),
                        .approx = if (e.approx != 0) e.approx else c.approx,
                        .split = split,
                    });
                }
            }
        }
        // A capture: the captured local itself, read again in this frame
        // after the demand (§18.8: the closure's own later reads of what it
        // gave up, as a send's payload, §23.7).
        for (cells.items) |e| {
            const x = w.cells.items[try w.takenBase(e.cell)];
            if (x.kind != .env or x.a >= w.local_frame.len or w.local_frame[x.a] == w.frame) continue;
            try holders.append(w.a, .{ .local = x.a, .path = x.path, .approx = e.approx });
        }
        rec.holders = try holders.toOwnedSlice(w.a);
        try w.demands.append(w.a, rec);
    }

    /// For an element a list pattern split off (§18.4 item 4), the element
    /// cell it stands for, which every holder but the pattern's own other
    /// bindings (`l` one of them: none) still holds.
    fn splitBase(w: *Walker, c: u32, l: u32) Allocator.Error!?u32 {
        const x = w.cells.items[c];
        if (x.kind != .taken) return null;
        const list = w.instCol(u32, w.split_list, x.b, none);
        if (list == none) return null;
        if (l != none and l < w.pat_site.len) if (w.pat_site[l]) |s| if (s.list.int() == list) return null;
        return try w.takenBase(c);
    }

    /// The callee of the call at `inst`, as written.
    fn callName(w: *Walker, inst: Inst.Index) Allocator.Error![]const u8 {
        const tag = w.bir.instTag(inst);
        if (tag == .call) {
            const callee: Inst.Index = @fromBackingInt(@intCast(w.bir.instData(inst).lhs));
            if (w.valueTarget(callee)) |t| return w.qualified(t);
            return "a function value";
        }
        if (tag == .method_call) {
            if (w.methodTarget(inst)) |t| return w.qualified(t);
            return "a method";
        }
        return "an operation";
    }

    fn localName(w: *const Walker, l: u32) []const u8 {
        const at = w.decl.locals_start + l;
        if (at >= w.bir.locals.len) return "_";
        const name = w.bir.locals[at].name.unwrap() orelse return "_";
        return w.o.in.interner.slice(w.bir.symbols[name]);
    }

    /// Where local `l` is bound: the token of the instruction that binds it
    /// (§28.6), `none` for a compiler-made local.
    fn localToken(w: *const Walker, l: u32) u32 {
        const at = w.decl.locals_start + l;
        if (at >= w.bir.locals.len) return none;
        const local = w.bir.locals[at];
        if (local.name.unwrap() == null) return none;
        if (w.bir.instTag(local.inst) != .let_def) {
            // A record pattern's binding carries the pattern's `{`: the
            // name is one of the identifiers after it.
            const tok = w.token(local.inst);
            const name = w.localName(l);
            const src = if (w.m < w.o.in.sources.len) w.o.in.sources[w.m] else return tok;
            const sp = w.o.in.spans[w.m];
            var k = tok;
            while (k < sp.tags.len and k < tok + 64) : (k += 1) {
                if (sp.tags[k] != .lower_ident) continue;
                const from = sp.starts[k];
                if (from + name.len > src.len or !std.mem.eql(u8, src[from..][0..name.len], name)) continue;
                const after = from + name.len;
                if (after < src.len and (std.ascii.isAlphanumeric(src[after]) or src[after] == '_')) continue;
                return k;
            }
            return tok;
        }
        // A `let_def` carries whatever token lowering met last; in a block
        // its name begins the line its `=` is on, before the value.
        const value: Inst.Index = @fromBackingInt(@intCast(w.bir.instData(local.inst).rhs));
        const lo = if (w.spanOf(value)) |s| s[0] else w.token(value);
        const tags = w.o.in.spans[w.m].tags;
        var k = lo;
        var guard: u32 = 0;
        while (k > 0 and tags[k - 1] != .equal and guard < 256) : (guard += 1) k -= 1;
        if (k == 0 or tags[k - 1] != .equal) return none;
        const line = w.pos(k - 1).line;
        var first = k - 1;
        while (first > 0 and w.pos(first - 1).line == line) first -= 1;
        return first;
    }

    fn baseText(w: *Walker, inst: Inst.Index) Allocator.Error![]const u8 {
        const out = w.o.out.allocator();
        var buf: std.Io.Writer.Allocating = .init(out);
        if (try w.writeExpr(&buf.writer, inst)) return buf.toOwnedSlice();
        buf.deinit();
        switch (w.bir.instTag(inst)) {
            .list => return "<literal>",
            .lambda => return "<lambda>",
            .record, .record_update => return "<record>",
            .tuple => return "<tuple>",
            .call => {
                if (w.isSpreadCall(inst)) return "<construction>";
                if (w.isListAppend(inst)) return "<++>";
                const callee: Inst.Index = @fromBackingInt(@intCast(w.bir.instData(inst).lhs));
                if (w.ctorName(callee)) |n| return std.fmt.allocPrint(out, "<{s} …>", .{n});
                if (w.valueTarget(callee)) |t| {
                    return std.fmt.allocPrint(out, "<call {s}.{s}>", .{ w.o.in.module_names[t.m], w.targetName(t) });
                }
                return "<call>";
            },
            .method_call => return "<call>",
            else => return w.ctorName(inst) orelse "<expression>",
        }
    }

    /// A constructor's name, as written.
    fn ctorName(w: *const Walker, inst: Inst.Index) ?[]const u8 {
        const data = w.bir.instData(inst);
        const m: u32, const i: u32 = switch (w.bir.instTag(inst)) {
            .ctor => .{ w.m, data.lhs },
            .ext_ctor => .{ data.lhs, if (data.lhs < w.o.in.provenance.len) w.o.in.provenance[data.lhs].ctorIndex(data.rhs) orelse return null else return null },
            else => return null,
        };
        if (m >= w.o.in.birs.len) return null;
        const bir = w.o.in.birs[m];
        if (i >= bir.ctors.len) return null;
        return w.o.in.interner.slice(bir.symbol(bir.ctors[i].name));
    }

    /// A variable or top-level value with a field path, as written.
    fn writeExpr(w: *Walker, wr: *std.Io.Writer, inst: Inst.Index) Allocator.Error!bool {
        const data = w.bir.instData(inst);
        switch (w.bir.instTag(inst)) {
            .local => wr.writeAll(w.localName(data.lhs)) catch return error.OutOfMemory,
            .top, .ext_value => {
                const t = w.valueTarget(inst) orelse return false;
                wr.print("{s}.{s}", .{ w.o.in.module_names[t.m], w.targetName(t) }) catch return error.OutOfMemory;
            },
            .field_access => {
                if (!try w.writeExpr(wr, @fromBackingInt(@intCast(data.lhs)))) return false;
                wr.print(".{s}", .{w.o.in.interner.slice(w.bir.symbol(@fromBackingInt(@intCast(data.rhs))))}) catch return error.OutOfMemory;
            },
            .tuple_index => {
                if (!try w.writeExpr(wr, @fromBackingInt(@intCast(data.lhs)))) return false;
                wr.print(".{d}", .{data.rhs}) catch return error.OutOfMemory;
            },
            else => return false,
        }
        return true;
    }

    /// The closure and position of a lambda's parameter cell.
    fn lambdaParam(w: *const Walker, c: Cell) ?[2]u32 {
        if (c.kind != .param or c.b != 1) return null;
        const at = c.a -% w.decl.inst_start.int();
        if (at >= w.pat_closure.len or w.pat_closure[at][0] == none) return null;
        return w.pat_closure[at];
    }

    /// Liveness, once every use is known (§7, §8.3); and the lambdas'
    /// demands on their own parameters, once every lambda's consumers are
    /// known (§16.5).
    fn resolve(w: *Walker, out_list: *std.ArrayList(Demand)) Allocator.Error!void {
        const out = w.o.out.allocator();
        // The uses by local, so that a holder's later uses are found
        // without a scan of every use (§18.11).
        const n = w.local_av.len;
        const start = try w.a.alloc(u32, n + 2);
        @memset(start, 0);
        for (w.uses.items) |u| if (u.local < n) {
            start[u.local + 2] += 1;
        };
        for (2..n + 2) |i| start[i] += start[i - 1];
        const order = try w.a.alloc(u32, start[n + 1]);
        for (w.uses.items, 0..) |u, ui| if (u.local < n) {
            order[start[u.local + 1]] = @intCast(ui);
            start[u.local + 1] += 1;
        };
        w.use_start = start[0 .. n + 1];
        w.use_order = order;
        // Probes and creations first: a once closure's writes read them —
        // last made first, so that a creation inside a once lambda reads the
        // probes of the lambda's own creation and calls, made after it.
        var i = w.demands.items.len;
        while (i > 0) {
            i -= 1;
            const rec = w.demands.items[i];
            if (rec.kind != .probe and rec.kind != .creation) continue;
            const verdict = try w.resolveOne(rec);
            w.probe_ok.items[rec.probe] = verdict.verdict != .rejected and verdict.verdict != .pending;
            w.probe_approx.items[rec.probe] = verdict.verdict != .rejected or verdict.approx;
            w.probe_info.items[rec.probe] = verdict;
        }
        for (w.demands.items) |rec| {
            if (rec.kind == .probe or rec.kind == .creation) continue;
            // A walk for a summary prints nothing: a line's verdict matters
            // only where the split may rely on an exclusive scrutinee
            // (§18.4 item 4), which a summary records (§18.11).
            if (w.mode != .report and (rec.base_local == none or rec.base_local >= w.pat_site.len or w.pat_site[rec.base_local] == null)) continue;
            const verdict = try w.resolveOne(rec);
            if (w.mode != .report) continue;
            try out_list.append(out, verdict);
        }
    }

    fn resolveOne(w: *Walker, rec: DemandRec) Allocator.Error!Demand {
        var d = try w.resolveRaw(rec);
        if (d.verdict == .rejected) switch (rec.origin) {
            .exact => {},
            // A write only a pessimistic summary claims (§16.7).
            .limit => {
                d.detail = try std.fmt.allocPrint(w.o.out.allocator(), "{s}; the callee's summary is past the checker's limits, so it is taken to write and keep its arguments", .{d.detail});
                d.verdict = .{ .rejected = .limit };
                d.approx = true;
            },
            // A write the callee makes only through an approximate step.
            .approx => if (!d.verdict.rejected.approximate()) {
                d.detail = try std.fmt.allocPrint(w.o.out.allocator(), "{s}; the callee writes it only through an approximate step", .{d.detail});
                d.verdict = .{ .rejected = .call };
                d.approx = true;
            },
        };
        // §20.6: the entry's acceptance is its row's.
        if (rec.entry != null and d.verdict == .accepted) {
            if (rec.entry.? == .template) {
                d.verdict = .{ .rejected = .platform };
                d.detail = "the platform's runtime keeps the model it hands update, and skips by identity; the direct row would accept it (§20.2)";
                d.approx = false;
                d.assumed = false;
                d.note = "";
            } else if (rec.accept != .param) {
                d.verdict = .{ .accepted = .entry };
            }
        }
        return d;
    }

    fn resolveRaw(w: *Walker, rec: DemandRec) Allocator.Error!Demand {
        const out = w.o.out.allocator();
        const position = w.pos(rec.token);
        var d: Demand = .{
            .position = position,
            .op = rec.op,
            .base = rec.base,
            .verdict = .{ .accepted = rec.accept },
            .detail = "",
            .note = rec.note,
            .token = rec.token,
            .span = rec.span,
            .base_span = rec.base_span,
            .top = rec.top,
            .via_token = rec.via,
        };
        if (rec.accept == .call and rec.assumed.len > 0) {
            d.assumed = true;
            d.note = try std.fmt.allocPrint(out, "no summary: {s}", .{rec.assumed});
        }
        if (rec.fixed) |f| {
            d.verdict = f.verdict;
            d.detail = f.detail;
            d.assumed = f.assumed;
            if (f.verdict == .rejected) d.approx = if (rec.prelim) |p| (p.approx orelse f.verdict.rejected.approximate()) else f.verdict.rejected.approximate();
            return d;
        }
        if (rec.prelim) |p| {
            d.verdict = .{ .rejected = p.cause };
            d.detail = p.detail;
            d.approx = p.approx orelse p.cause.approximate();
            d.assumed = false;
            return d;
        }
        // Each holder's first later use in a compatible branch.
        var best: ?struct { cause: Cause, holder: Holder, use: Use } = null;
        for (rec.holders) |h| {
            var first: ?Use = null;
            const range = if (h.local < w.use_start.len - 1) w.use_order[w.use_start[h.local]..w.use_start[h.local + 1]] else &[_]u32{};
            for (range) |ui| {
                const u = w.uses.items[ui];
                if (u.local != h.local or u.frame != rec.frame or u.point <= rec.point) continue;
                if (rec.creation_ci != none and u.via == rec.creation_ci) continue;
                if (!w.compatible(u.ctx, rec.ctx)) continue;
                if (!w.useOverlaps(u, h.path)) continue;
                if (first == null or u.point < first.?.point) first = u;
            }
            const u = first orelse continue;
            // §18.4 item 4, the split: another binding of the same list
            // pattern holds another position, apart when the scrutinee's
            // contents are exclusive.
            if (try w.splitSibling(rec, h)) continue;
            const cause: Cause = if (h.approx != 0)
                .call
            else if (h.local == rec.base_local and w.o.overlap(h.path, rec.base_path) and !w.o.hasStep(h.path, .env))
                .later_use
            else if (h.split)
                .alias
            else if (rec.element and try w.o.representative(h.path))
                .element
            else if (w.o.hasStep(h.path, .env))
                .captured
            else if (h.local == rec.base_local and w.o.overlap(h.path, rec.base_path))
                .later_use
            else
                .alias;
            if (best) |bst| {
                const better_kind = cause.approximate() != bst.cause.approximate() and !cause.approximate();
                const same_kind = cause.approximate() == bst.cause.approximate();
                if (!(better_kind or (same_kind and (u.point < bst.use.point or (u.point == bst.use.point and w.holderBefore(h, bst.holder)))))) continue;
            }
            best = .{ .cause = cause, .holder = h, .use = u };
        }
        if (best) |bst| {
            const up = w.pos(bst.use.token);
            var buf: std.Io.Writer.Allocating = .init(out);
            const wr = &buf.writer;
            wr.writeAll(w.localName(bst.holder.local)) catch return error.OutOfMemory;
            if (bst.cause != .captured) w.o.writePath(wr, bst.holder.path) catch return error.OutOfMemory;
            // §28.6: the holder, where it was bound, and the read.
            d.holder = try out.dupe(u8, buf.written());
            d.keep_token = w.localToken(bst.holder.local);
            d.read_span = if (bst.use.at[0] != none) bst.use.at else .{ bst.use.token, bst.use.token };
            if (bst.cause == .call) d.via_token = w.token(@fromBackingInt(@intCast(bst.holder.approx - 1)));
            switch (bst.cause) {
                .later_use => wr.print(" is read again at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                .captured => wr.print(", a closure holding it, is used at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
                .call => {
                    const call_inst: Inst.Index = @fromBackingInt(@intCast(bst.holder.approx - 1));
                    const cp = w.pos(w.token(call_inst));
                    wr.print(" may hold it through the call at {d}:{d}, and is read at {d}:{d}", .{ cp.line, cp.col, up.line, up.col }) catch return error.OutOfMemory;
                },
                else => wr.print(" holds it and is read at {d}:{d}", .{ up.line, up.col }) catch return error.OutOfMemory,
            }
            d.verdict = .{ .rejected = bst.cause };
            d.detail = try buf.toOwnedSlice();
            d.approx = bst.cause.approximate();
            d.assumed = false;
            return d;
        }
        // §18.4: exclusive contents the write needs and may not have.
        if (rec.xfail) |r| {
            d.verdict = .{ .rejected = .exclusive };
            d.detail = rec.xdetail;
            d.approx = r == .approx;
            d.assumed = false;
            return d;
        }
        // A write of a capture: what the once closure's creation and calls
        // decide (§18.8).
        if (rec.once_ci != none) return w.decideOnce(rec, d);
        // A lambda's demand on its own parameter: what its consumers decide.
        if (rec.accept == .callback_param) try w.decideCallback(rec, &d);
        return d;
    }

    fn decideOnce(w: *Walker, rec: DemandRec, d_in: Demand) Allocator.Error!Demand {
        var d = d_in;
        const cl = &w.closures.items[rec.once_ci];
        d.assumed = false;
        d.note = "";
        // Its creation fails exactly — a live holder of what it captured, the
        // model still holding a list a body sends (§23.7) — which names the
        // holder; then a place known to call it more than once rejects it,
        // wherever else it goes (a command's body, which may run again).
        for (cl.once_probes.items) |p| {
            const info = w.probe_info.items[p] orelse continue;
            if (info.verdict != .rejected or info.approx) continue;
            d.verdict = info.verdict;
            d.detail = info.detail;
            d.approx = false;
            return d;
        }
        if (cl.once_bad) |why| {
            d.verdict = .{ .rejected = .once };
            d.detail = why;
            d.approx = cl.once_bad_approx;
            return d;
        }
        for (cl.consumed.items) |c| if (c.kind == .pending) {
            d.verdict = .pending;
            d.detail = c.why;
            return d;
        };
        for (cl.consumed.items) |c| if (c.kind == .no_summary) {
            d.verdict = .{ .rejected = .once };
            d.detail = try std.fmt.allocPrint(w.o.out.allocator(), "it is handed to {s}, which has no summary and may call it more than once", .{c.name});
            d.approx = true;
            return d;
        };
        for (cl.once_probes.items) |p| {
            const info = w.probe_info.items[p] orelse continue;
            if (info.verdict == .accepted) continue;
            d.verdict = info.verdict;
            d.detail = info.detail;
            d.approx = info.approx;
            return d;
        }
        // A call of it is a demand on its own cell: a holder read after a
        // call is a second call (§18.8).
        for (cl.call_probes.items) |p| {
            const info = w.probe_info.items[p] orelse continue;
            if (info.verdict == .accepted) continue;
            d.verdict = .{ .rejected = .once };
            d.detail = try std.fmt.allocPrint(w.o.out.allocator(), "it may run more than once: {s}", .{info.detail});
            d.approx = info.approx;
            return d;
        }
        d.verdict = .{ .accepted = .once };
        return d;
    }

    fn decideCallback(w: *Walker, rec: DemandRec, d: *Demand) Allocator.Error!void {
        const out = w.o.out.allocator();
        var lp: ?[2]u32 = null;
        for (rec.cells) |e| {
            if (w.lambdaParam(w.cells.items[try w.takenBase(e.cell)])) |x| {
                lp = x;
                break;
            }
        }
        const x = lp orelse return;
        const cl = &w.closures.items[x[0]];
        // The worst consumer decides: pending, then rejected, then a callee
        // with no summary, then accepted.
        var rank: u8 = 0;
        for (cl.consumed.items) |c| switch (c.kind) {
            .pending => if (rank < 3) {
                rank = 3;
                d.verdict = .pending;
                d.detail = c.why;
                d.note = "";
                d.assumed = false;
            },
            .supply => if (rank < 2 and x[1] < c.bad.len) {
                if (c.bad[x[1]]) |why| {
                    rank = 2;
                    d.verdict = .{ .rejected = if (x[1] < c.bad_cause.len) c.bad_cause[x[1]] else .supply };
                    d.detail = why;
                    d.approx = c.bad_approx[x[1]];
                    d.note = "";
                    d.assumed = false;
                } else if (rank == 0) {
                    d.note = try std.fmt.allocPrint(out, "{s} supplies it owned", .{c.name});
                }
            },
            .no_summary => if (rank < 1) {
                rank = 1;
                d.assumed = true;
                d.note = try std.fmt.allocPrint(out, "no summary: {s}", .{c.name});
            },
            .local => if (rank == 0 and d.note.len == 0) {
                d.note = "decided at its calls";
            },
        };
    }

    fn splitSibling(w: *Walker, rec: DemandRec, h: Holder) Allocator.Error!bool {
        if (rec.base_local == none or rec.base_local >= w.pat_site.len or h.local >= w.pat_site.len) return false;
        const b = w.pat_site[rec.base_local] orelse return false;
        const s = w.pat_site[h.local] orelse return false;
        if (b.list != s.list or b.index == s.index or b.spread) return false;
        return try w.rely(try w.deepCond(s.scrut), rec.frame) == .ok;
    }

    /// A tie-break between two holders read at one point that depends on the
    /// text alone — the local, then the path as written, then the call —
    /// never on an id, which other declarations' walks move.
    fn holderBefore(w: *const Walker, a: Holder, b: Holder) bool {
        if (a.local != b.local) return a.local < b.local;
        var ba: [256]u8 = undefined;
        var bb: [256]u8 = undefined;
        var wa: std.Io.Writer = .fixed(&ba);
        var wb: std.Io.Writer = .fixed(&bb);
        w.o.writePath(&wa, a.path) catch {};
        w.o.writePath(&wb, b.path) catch {};
        const o = std.mem.order(u8, wa.buffered(), wb.buffered());
        if (o != .eq) return o == .lt;
        return a.approx < b.approx;
    }

    fn useOverlaps(w: *const Walker, u: Use, path: u32) bool {
        if (u.except.len != 0 and u.path == eps) {
            const first = w.o.firstStep(path) orelse return true;
            if (first.kind == .field and std.mem.indexOfScalar(u32, u.except, first.arg) != null) return false;
            return true;
        }
        return w.o.overlap(u.path, path);
    }

    // ---- reading off (§16.3) -----------------------------------------------

    /// The declaration's summary, once the walk is resolved.
    fn readOff(w: *Walker) Allocator.Error!Summary {
        return w.readOffFrame(0, w.params, w.result_av);
    }

    /// The parameter index a cell is of, in frame `frame` whose parameters
    /// are `params`.
    fn paramIndex(_: *const Walker, c: Cell, frame: u32, params: []const Inst.Index) ?u32 {
        if (c.kind != .param) return null;
        if (frame == 0 and c.b != 0) return null;
        if (frame != 0 and c.b != 1) return null;
        for (params, 0..) |p, i| if (p.int() == c.a) return @intCast(i);
        return null;
    }

    fn readOffFrame(w: *Walker, frame: u32, params: []const Inst.Index, result: AV) Allocator.Error!Summary {
        const keep = w.o.keep.allocator();
        var uses: std.ArrayList(UseEntry) = .empty;
        // R: a use of a local whose value holds a parameter cell.
        for (w.uses.items) |u| {
            if (u.frame != frame) continue;
            const held = w.local_av[u.local] orelse continue;
            for (held) |e| {
                const c = w.cells.items[try w.takenBase(e.cell)];
                const pi = w.paramIndex(c, frame, params) orelse continue;
                if (u.except.len != 0 and u.path == eps) {
                    if (w.o.firstStep(e.path)) |first| {
                        if (first.kind == .field and std.mem.indexOfScalar(u32, u.except, first.arg) != null) continue;
                    } else if (w.recordFields(w.localType(u.local))) |fields| {
                        // A record update reads every field but the ones it
                        // replaces (§5's split, §16.4 item 1).
                        for (fields) |fl| {
                            if (std.mem.indexOfScalar(u32, u.except, @backingInt(fl.name)) != null) continue;
                            if (!try w.trackedVar(fl.value)) continue;
                            try uses.append(keep, .{ .param = pi, .path = try w.o.child(c.path, .field, @backingInt(fl.name)), .bits = bit_r });
                        }
                        continue;
                    }
                } else if (!w.o.overlap(e.path, u.path)) continue;
                var path = c.path;
                if (try w.o.suffix(e.path, u.path)) |rest| path = try w.o.concat(path, rest);
                try uses.append(keep, .{ .param = pi, .path = path, .bits = bit_r });
            }
        }
        // W: a demand's cells, in this frame or, through a capture, inside
        // a lambda of it.
        for (w.demands.items) |rec| {
            if (rec.kind == .probe or rec.kind == .value) continue;
            for (rec.cells) |e| {
                const c = w.cells.items[try w.takenBase(e.cell)];
                const deep: u8 = if (rec.deep) bit_d else 0;
                if (rec.frame == frame) {
                    if (w.paramIndex(c, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = c.path, .bits = bit_w | deep | (if (e.approx == 0 and rec.origin == .exact) bit_x else 0) });
                }
                if (c.kind == .env and rec.frame != frame) {
                    const held = w.local_av[c.a] orelse continue;
                    if (c.a >= w.local_frame.len or w.local_frame[c.a] != frame) continue;
                    for (try w.projPath(held, c.path, null)) |h| {
                        if (h.path != eps) continue;
                        const hc = w.cells.items[h.cell];
                        if (w.paramIndex(hc, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = hc.path, .bits = bit_w | deep | (if (e.approx == 0 and h.approx == 0 and rec.origin == .exact) bit_x else 0) });
                    }
                }
            }
        }
        // E: a parameter cell in Esc.
        for (w.escaped.items) |x| {
            const c = w.cells.items[try w.takenBase(x.cell)];
            if (w.paramIndex(c, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = c.path, .bits = if (x.why != 0) bit_j else bit_e });
        }
        // A and the result.
        const expanded = try w.expand(result);
        var fresh_cells: std.ArrayList(u32) = .empty;
        for (expanded) |e| {
            const k = w.cells.items[e.cell].kind;
            if (k == .site or k == .result) {
                if (std.mem.indexOfScalar(u32, fresh_cells.items, e.cell) == null) try fresh_cells.append(w.a, e.cell);
            }
        }
        std.mem.sort(u32, fresh_cells.items, w, struct {
            fn less(ww: *Walker, x: u32, y: u32) bool {
                const cx = ww.cells.items[x];
                const cy = ww.cells.items[y];
                if (cx.a != cy.a) return cx.a < cy.a;
                if (cx.b != cy.b) return cx.b < cy.b;
                return cx.path < cy.path;
            }
        }.less);
        // A fresh number only says which result paths may hold one new
        // cell (thesis §3.7, §4.6: `k ≤ |Q|`), so cells that appear at the
        // same paths share a number; the numbering stays a function of the
        // result's shape, not of how many literals the body has.
        const renum = try w.a.alloc(u32, fresh_cells.items.len);
        var groups: std.ArrayList([]const u32) = .empty;
        for (fresh_cells.items, renum) |fc, *num| {
            var ps: std.ArrayList(u32) = .empty;
            for (expanded) |e| {
                if (e.cell != fc) continue;
                const key = e.path *% 2 +% @intFromBool(e.approx != 0);
                if (std.mem.indexOfScalar(u32, ps.items, key) == null) try ps.append(w.a, key);
            }
            std.mem.sort(u32, ps.items, {}, std.sort.asc(u32));
            const esc_bit: u32 = if (try w.isEscaped(fc)) 1 else 0;
            try ps.append(w.a, esc_bit);
            var found: ?usize = null;
            for (groups.items, 0..) |g, gi| if (std.mem.eql(u32, g, ps.items)) {
                found = gi;
                break;
            };
            const gi = found orelse blk: {
                try groups.append(w.a, ps.items);
                break :blk groups.items.len - 1;
            };
            num.* = @intCast(gi + 1);
        }
        var res: std.ArrayList(ResEntry) = .empty;
        var klasses: std.ArrayList(Carried) = .empty;
        for (expanded) |e| {
            // §24.9: a lambda the result holds keeps its class, when it is
            // one a caller can call with nothing but its result and reads.
            if (frame == 0 and !w.recursive and w.cells.items[e.cell].kind == .closure and !w.o.hasStep(e.path, .env)) {
                if (try w.carried(w.cells.items[e.cell].a, params, fresh_cells.items)) |k| {
                    try klasses.append(keep, k);
                    try res.append(keep, .{ .path = e.path, .prov = .{ .kind = .klass, .a = @intCast(klasses.items.len - 1) }, .approx = e.approx != 0 });
                }
                continue;
            }
            const c = w.cells.items[try w.takenBase(e.cell)];
            const own = w.paramIndex(c, frame, params) != null;
            if (w.paramIndex(c, frame, params)) |pi| try uses.append(keep, .{ .param = pi, .path = c.path, .bits = bit_a });
            var prov = (try w.provOf(e.cell, frame, params, fresh_cells.items)) orelse continue;
            if ((prov.kind == .fresh or prov.kind == .esc) and prov.a > 0) prov.a = renum[prov.a - 1];
            prov.taken = false;
            // §18.3: the cell's condition, a parameter's own `excl` left to
            // instantiation.
            const xc = try w.xsumOf(try w.cellCond(e.cell), frame, params, if (own and w.cells.items[e.cell].kind != .taken) e.cell else none);
            const sc = try w.xsumOf(try w.spineAt(expanded, e), frame, params, if (own and w.cells.items[e.cell].kind != .taken) e.cell else none);
            try res.append(keep, .{ .path = e.path, .prov = prov, .approx = e.approx != 0, .xc = xc, .sc = sc });
        }
        // Function parameters.
        var funs: std.ArrayList(FunFacts) = .empty;
        var supply: std.ArrayList(SupplyEntry) = .empty;
        if (frame == 0) {
            for (w.fn_state.items, 0..) |st, j| {
                if (!st.is_fn) continue;
                var need = st.need;
                for (w.demands.items) |rec| {
                    if (rec.kind == .probe or rec.kind == .value) continue;
                    for (rec.cells) |e| {
                        const c = w.cells.items[e.cell];
                        if (c.kind == .cbres and c.a == j) need = true;
                    }
                }
                try funs.append(keep, .{ .param = @intCast(j), .calls = st.calls, .need = need, .seen = st.seen, .send = st.send });
            }
            var atoms: u32 = 0;
            for (w.supplies.items) |sr| {
                const owned_probe = sr.owned and (sr.probe == none or w.probe_ok.items[sr.probe]) and (sr.probe2 == none or w.probe_ok.items[sr.probe2]);
                const probe_approx = if (!sr.owned) sr.approx else (sr.probe != none or sr.probe2 != none) and (sr.probe == none or w.probe_approx.items[sr.probe]) and (sr.probe2 == none or w.probe_approx.items[sr.probe2]);
                const xc = try w.xsumOf(sr.cond, frame, params, none);
                for (try w.expand(sr.av)) |e| {
                    var prov = (try w.provOf(e.cell, frame, params, &.{})) orelse continue;
                    if (prov.kind == .fresh or prov.kind == .esc) prov.a = 0;
                    if (sr.taken and prov.kind == .param) prov.taken = true;
                    var owned = owned_probe and prov.kind != .shared and prov.kind != .top and prov.kind != .esc and prov.kind != .env;
                    if (prov.kind == .cb and owned) {
                        atoms += 1;
                        if (atoms > atom_cap) owned = false;
                    }
                    // Shared is the position rule, exact; ⊤, an escape and a
                    // capture are limits, as is a probe that failed only
                    // through one.
                    const approx = !owned and switch (prov.kind) {
                        .shared => false,
                        .top, .esc, .env => true,
                        else => probe_approx or e.approx != 0,
                    };
                    try supply.append(keep, .{ .fun = sr.fun, .k = sr.k, .path = try w.o.concat(sr.path, e.path), .prov = prov, .owned = owned, .approx = approx, .xc = xc });
                }
            }
        } else {
            // A lambda's own function parameters: its class does not follow
            // them (§16.5).
            for (params, 0..) |p, k| {
                const v = w.patternType(p) orelse continue;
                if (isFunc(w.store, v)) try funs.append(keep, .{ .param = @intCast(k), .calls = .many, .seen = false });
            }
        }
        // §18.4: what the frame relied on.
        var xreq: std.ArrayList(XAtom) = .empty;
        for (w.reqs.items) |r| {
            if (r.frame != frame) continue;
            if (try w.xatomOf(r.atom, frame, params)) |x| try xreq.append(keep, x);
        }
        return w.o.normalize(.{
            .params = @intCast(params.len),
            .uses = uses.items,
            .res = res.items,
            .supply = supply.items,
            .funs = funs.items,
            .xreq = xreq.items,
            .slots = if (frame == 0) try keep.dupe([2]u32, w.slot_keys.items) else &.{},
            .klasses = klasses.items,
        });
    }

    /// The provenance a cell is read off as (thesis §4.4).
    fn provOf(w: *Walker, cell_id: u32, frame: u32, params: []const Inst.Index, fresh: []const u32) Allocator.Error!?Prov {
        const c = w.cells.items[cell_id];
        switch (c.kind) {
            .param => {
                if (w.paramIndex(c, frame, params)) |pi| return .{ .kind = .param, .a = pi, .path = c.path };
                return .{ .kind = .top };
            },
            .site, .result => {
                const k: u32 = if (std.mem.indexOfScalar(u32, fresh, cell_id)) |i| @intCast(i + 1) else 0;
                return .{ .kind = if (try w.isEscaped(cell_id)) .esc else .fresh, .a = k };
            },
            .env => {
                if (frame == 0) return .{ .kind = .top };
                return .{ .kind = .env, .a = c.a, .path = c.path };
            },
            .shared => return .{ .kind = .shared, .a = c.a, .b = c.b, .path = c.path },
            // `a` 1: a ⊤ a pessimistic summary made (§16.7).
            .top => return .{ .kind = .top, .a = c.a },
            // A message, which only the entry computation names (§20.5).
            .payload => return .{ .kind = .top },
            .cbres => {
                // In a lambda: the declaration's callback result, called inside it (§18.9).
                if (frame != 0) return .{ .kind = .cb, .a = c.a, .b = 1, .path = c.path };
                return .{ .kind = .cb, .a = c.a, .path = c.path };
            },
            // The element it stands for, taken (§18.5).
            .taken => {
                var p = (try w.provOf(try w.takenBase(cell_id), frame, params, fresh)) orelse return null;
                if (p.kind == .param) p.taken = true;
                return p;
            },
            .closure, .func => return null,
        }
    }
};
