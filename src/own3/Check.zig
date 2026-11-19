//! own3, layer 4: one module (`ownership-v3-kernel.md` §7; research report
//! 110 §6.7; report 111 §2).
//!
//! The declarations of a module are walked in dependency order, callees
//! first (`own2/Prepass.zig` gives the groups). A group that calls itself is
//! walked again until no contract of it changes: the contracts start empty
//! and only grow, so the last round's verdicts stand on the least fixed
//! point. A declaration with ownership words is not walked: its words are
//! its contract (`wordedContract`). A `foreign` with no word has no contract,
//! and so has a declaration whose walk gave up: a call of either lets each
//! argument escape, and its answer can hold each argument.
//!
//! The place graph is `own2/Place.zig`'s, read through `own2/Groups.zig`'s
//! adapter. Nothing else of the ownership checker v2 runs here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const OwnHoists = @import("Reads.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Ast = @import("../parse/Ast.zig");
const Ids = @import("../own2/Ids.zig");
const Place = @import("../own2/Place.zig");
const Groups = @import("../own2/Groups.zig");
const Prepass = @import("../own2/Prepass.zig");
const Facts = @import("../own2/Facts.zig");
const Message = @import("../own2/Message.zig");
const InternPool = @import("../InternPool.zig");
const Loc = @import("Loc.zig");
const Contract = @import("Contract.zig");
const Frame = @import("Frame.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Edges = @import("../check/Edges.zig");

const PlaceId = Ids.PlaceId;
const Step = Place.Step;
const Inst = Bir.Inst;
const Var = TypeStore.Var;
const Src = Contract.Src;
const W = Ast.OwnWord;
const none = Loc.none;

/// The most units of work that one declaration may do over all of its walks,
/// whatever it earns (kernel §8, `Mod.declBudget`): about 16 times the
/// largest declaration of an ownership root (research report 138).
pub const max_walk_steps: u64 = 1 << 25;

/// The units of one call of a walk (`Frame.tick`): about what a call costs
/// beside the loops inside it, which count their own elements
/// (`Frame.charge`). So the budget is about a million calls (kernel §8).
pub const call_units: u64 = 32;

/// The units of work that a module earns for each instruction that a walk
/// evaluates and that is not part of a literal (kernel §8): a reference, a
/// call, a binding, a pattern, a `case`, a function. Its walks and its
/// location table together spend them (`Mod.overBudget`), over and above
/// `module_floor`, and the declaration it is in its own budget (`Mod.declBudget`).
/// A thousand calls of a walk: at a quarter of it, `NotesApp.viewSidebar` of
/// `bench/corpus` and `Ui.Html.map` would pass their budgets (research report 138).
pub const inst_units: u64 = 1 << 15;

/// The units of work that every declaration may do, whatever its size
/// (kernel §8), over and above what its own instructions earn: a small
/// function that reads the large contracts of its callees costs far more
/// than its own instructions (`Dict.descend` of `core/`: 22 instructions,
/// 0.93 million units; research report 138).
pub const decl_floor: u64 = 1 << 20;

/// The units of work that a declaration earns for each entry of the layout
/// of each of its instructions that a walk evaluates (kernel §8): a walk of
/// a value visits each entry of its layout a few times, a call each
/// (`Frame.tick`), and the duplicate test groups each of its cells
/// (`Frame.runsShare`): `f p = p` over nested pairs of 4 096 lists took
/// 52 units for each entry of its two instructions (research report 138).
pub const layout_units: u64 = 1 << 7;

/// The units of work of each store variable that the adapter closes, and of
/// each field of a record that it reads (`Mod.chargePlaces`, kernel §8): a
/// lookup in its table of variables, and the hash of the node it makes. Measured on instances of a record of 3 000
/// fields (research report 145).
pub const var_units: u64 = Loc.lookup_units;

/// The units of work that a module earns for each instruction of a literal
/// (kernel §8): a number, a character, a string, `⊤`, a constructor named, a
/// negated number, and a tuple, a list, a record or a constructor applied
/// whose elements are all literals. The walk of a literal evaluates each of
/// its instructions once, a call each (`call_units`), and the place graph
/// adds the places of its type: a literal of numbers took 32 units for each,
/// and a tuple nested 511 deep 80 for each of its instructions (research
/// report 136). Four calls.
pub const literal_units: u64 = 4 * call_units;

/// The units of work that a literal earns for each pair of two lists in it
/// (kernel §8): its walk tests each pair of its cells (`deriveLinear`), and
/// a literal of `n` fresh lists took about n²/2 units and 142 for each
/// (research report 136). Twice that.
pub const pair_units: u64 = 2;

/// The units of work that a module earns for each instruction of a type or
/// of a schema's plan (kernel §8): no walk evaluates one, and the location
/// table counts the places and layouts that it builds for them: an
/// annotation nested 511 deep took 48 units for each of its instructions
/// (research report 136). Four calls.
pub const type_units: u64 = 4 * call_units;

/// The units of work that every module may do, whatever its size (kernel §8).
pub const module_floor: u64 = 1 << 16;

/// The most units of work that any module may do (kernel §8): about 15 times
/// the most that a module of an ownership root does, and about 1.6 s of work
/// at the slowest unit of v3's own walks measured, 12 ns (research report 135).
pub const module_cap: u64 = 1 << 27;

/// The budget of a module that earned `earned` units (`Mod.earnedUnits`,
/// kernel §8). So the work of a module is linear in its instructions, at
/// most `module_cap`, and the work of a build in the sum over its modules.
pub fn moduleBudget(earned: u64) u64 {
    return @min(module_floor +| earned, module_cap);
}

/// The text of a module's limit line: the budget, and where it comes from.
pub fn moduleLimitText(arena: Allocator, name: []const u8, budget: u64, insts: usize) Allocator.Error![]const u8 {
    if (budget == module_cap) return std.fmt.allocPrint(arena, "limit {s}: the walks of the module took more than {d} units of work (the most for any module), so the checker judges no write of the module", .{ name, budget });
    return std.fmt.allocPrint(arena, "limit {s}: the walks of the module took more than {d} units of work ({d}, and what its {d} instructions and their declarations earn), so the checker judges no write of the module", .{ name, budget, module_floor, insts });
}

pub const Names = Message.Names;

/// What the modules of one run share: each module's contracts, written once
/// by the worker that checked it, before any importer runs.
pub const Shared = struct {
    published: []?*Contract.Published,
};

pub const Line = struct {
    /// The instruction the lowering channel names, and the token of the position.
    inst: u32,
    token: u32,
    kind: Facts.DemandKind,
    op: []const u8,
    base: []const u8,
    refused: bool,
    accepted: Facts.Verdict.Accepted = .fresh,
    cause: Facts.Cause = .unknown,
    detail: []const u8 = "",
    /// The write is of a record's field slot (kernel §11).
    record: bool = false,
    /// A refusal of a function handed as evidence (`Frame.evidence`), which
    /// every package's build enforces (kernel §6 rule 11).
    evidence: bool = false,
    /// `update`: the later reads the lowering reads before the stores (kernel §11).
    hoists: []const OwnHoists.Read = &.{},
};

/// A limit line (kernel §8) and the token it points at: the name of the
/// declaration or of the type that reached the limit, or `null` for the
/// module as a whole. Research report 141: the lines pointed at
/// instruction 0, an unrelated declaration.
pub const Limit = struct {
    text: []const u8,
    token: ?u32,
};

pub const Result = struct {
    lines: []const Line,
    published: *Contract.Published,
    /// Declarations that the walk gave up on (a nesting too deep, a group that did not settle).
    limits: []const Limit,
    /// Each declaration's contract as text, when asked for.
    summaries: []const []const u8,
    /// The worded declarations whose body reaches no JavaScript and whose
    /// walk found what their words do not say (kernel §6 rule 10, *A worded
    /// body is checked against its walk*): every package's build refuses
    /// each (`Enforce.checkModule`).
    false_words: []const Limit = &.{},
};

/// The build's markup type (`boundary.md` §9.2), by the names the manifest
/// gives: a function of an entry's record that answers it is a `view`, and
/// what its answer holds is rendered before the runtime runs `update` again
/// (`boundary.md` §9.4.8, kernel §6.12).
pub const MarkupType = struct { module: InternPool.Symbol, name: InternPool.Symbol };

pub const Options = struct {
    summaries: bool = false,
    markup_type: ?MarkupType = null,
    /// A `--library` build of a module of the root package: host
    /// JavaScript calls each value it exports (kernel §6.14).
    library: bool = false,
    /// The `let_def` instructions whose values the build's markup lowering
    /// keeps beyond the call that made them, ascending (kernel §6.14,
    /// `Enforce.keptLets`): each is held by the root that keeps it.
    kept_lets: []const u32 = &.{},
    /// A module of core or a platform, the packages that may write
    /// ownership words: which of its bodies reach JavaScript is worked out
    /// and published (`reachesJs`), for its worded bodies and for those of
    /// the modules that import it. An application's module has no word, and
    /// publishes none: an importer reads each of its declarations as one
    /// that reaches JavaScript.
    rows: bool = false,
};

const State = enum(u8) { todo, working, done };

/// What code named by dispatch terms can do (`Mod.termsInfo`): the join of
/// the effects of its edges, and which texts of a refusal of evidence they
/// make, one bit each (`textBit`).
pub const RowInfo = struct {
    effect: Contract.Effect = .{},
    texts: u4 = 0,

    pub fn addEffect(r: *RowInfo, x: Contract.Effect) void {
        r.effect = r.effect.join(x);
        r.texts |= textBit(x);
    }

    pub fn add(r: *RowInfo, x: RowInfo) void {
        r.effect = r.effect.join(x.effect);
        r.texts |= x.texts;
    }

    pub fn eql(a: RowInfo, b: RowInfo) bool {
        return std.meta.eql(a.effect, b.effect) and a.texts == b.texts;
    }

    /// The bit of the text that `Mod.evidenceText` gives `x`, or 0.
    fn textBit(x: Contract.Effect) u4 {
        if (!x.any()) return 0;
        if (x.writes) return 1;
        if (x.keeps) return 2;
        if (x.rewrites) return 4;
        return 8;
    }

    /// The text of bit `b` (`textBit`).
    pub fn text(b: u4) []const u8 {
        return Mod.evidenceText(switch (b) {
            1 => .{ .writes = true },
            2 => .{ .keeps = true },
            4 => .{ .rewrites = true },
            else => .{ .no_contract = true },
        });
    }
};

const RefusalKey = struct { inst: u32, cause: u32, detail: u64 };

pub const Mod = struct {
    gpa: Allocator,
    /// Lives as long as the module's result.
    arena: Allocator,
    walk_arena: std.heap.ArenaAllocator,
    /// The set of atoms that `Frame.uniqueTail` keeps while it removes the
    /// repeats of a run: one table for the module, cleared for each run.
    uniq_seen: std.AutoHashMapUnmanaged(Frame.Atom, void) = .empty,
    /// The scratch of `Frame.runsShare`, the one duplicate test of a set of
    /// runs: one table for the module, cleared for each test.
    share: Frame.ShareScratch = .{},
    in: *const Groups.Input,
    bir: *const Bir,
    tags: []const Inst.Tag,
    datas: []const Inst.Data,
    tokens: []const u32,
    names: Names,
    shared: *const Shared,
    /// The build's markup type, when it has one (`Options.markup_type`).
    markup_type: ?MarkupType = null,
    /// `Options.kept_lets`.
    kept_lets: []const u32 = &.{},

    places: Place.Table = .{},
    account: Ids.Account = .{ .allowance = std.math.maxInt(u32) },
    adapter: Groups.Adapter = undefined,
    loc: Loc.Table = undefined,
    prepass: Facts.Prepass = undefined,
    var_place: PlaceId = undefined,

    next_frame: u32 = 1,
    /// The next match of a list pattern whose parts are apart (`Frame.listParts`,
    /// kernel §4.4): one for each run of its binding in the module's walks.
    next_match: u32 = 0,
    /// Per local of the module: its value and its frame, while its declaration is walked.
    lv: []Frame.Val = &.{},
    lframe: []u32 = &.{},
    /// Per local of the module: the frame whose `let` binds it, set where
    /// that frame enters the `let` (`Frame.enterLet`). A local that a frame
    /// names before it is bound is the frame's own (a later binding of its
    /// own `let`) or a capture (a later binding of an enclosing frame's).
    lbinder: []u32 = &.{},
    /// Per local of the module: the binding of a local function, or of a
    /// value whose right side is a lambda (a code binding), or `none`.
    lcode: []u32 = &.{},
    /// Per local of the module: the cyclic group of code bindings that it is
    /// in, an index of `groups`, or `none`.
    lgroup: []u32 = &.{},
    /// Per local of the module: scratch for `Frame.findGroups`, `none` outside it.
    lindex: []u32 = &.{},
    /// The cyclic groups of code bindings: their bindings, in written order.
    groups: std.ArrayList([]const u32) = .empty,
    /// Per `let` instruction: its code bindings and groups are known.
    let_seen: std.DynamicBitSetUnmanaged = .{},
    /// Per code instruction: a walk named the code while its rounds ran
    /// (`Frame.memberValue`), so its contract so far was read.
    recalled: []bool = &.{},
    /// Per instruction: the contract of the lambda or local function there.
    code_contract: []?*const Contract.Contract = &.{},
    /// Per instruction: the locals that the code there captured in its last
    /// walk, in the order of its contract's parameters after its own.
    code_caps: [][]const u32 = &.{},
    contracts: []?*const Contract.Contract = &.{},
    /// Per declaration: its last walk gave up, so it must publish no contract (kernel §3.3; asserted at `publish`).
    failed_decl: []bool = &.{},
    /// The contracts of a group whose rounds run (`solveGroup`,
    /// `Frame.solveCodes`): a fresh cell of one of them is named by the call
    /// alone (`Frame.freshAtom`), so the rounds settle (kernel §4.2).
    drafts: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// The allocation sites of this module's contracts: a small number for
    /// each site name, the same in each round (`siteId`).
    sites: std.AutoHashMapUnmanaged(u64, u16) = .empty,
    state: []State = &.{},
    worded_done: []bool = &.{},
    readers: []?Contract.Reader = &.{},
    spread_root: std.DynamicBitSetUnmanaged = .{},
    lines: std.ArrayList(Line) = .empty,
    limits: std.ArrayList(Limit) = .empty,
    /// Per declaration: its body reaches JavaScript (`reachesJs`).
    js: []bool = &.{},
    /// The worded declarations whose walk found what their words do not
    /// say (`falseWord`, kernel §6 rule 10), at each one's name.
    false_words: std.ArrayList(Limit) = .empty,
    /// The declaration whose budget or walk first met a type past the
    /// layout limit (`Loc.Table.over`), for the limit line's position.
    over_decl: ?u32 = null,
    /// By declaration: its position in the recursive group whose order
    /// `groupOrder` makes, else `none`.
    group_pos: []u32 = &.{},
    /// The steps that the declaration in work took so far, over all of its
    /// walks (`Frame.tick`), and whether it passed `max_walk_steps` (kernel
    /// §8). One budget for each declaration: every round of its group, the
    /// entry's fixed point and every other loop that no memo bounds count
    /// against it (`decl_steps`).
    steps: u64 = 0,
    steps_over: bool = false,
    /// A declaration of the module passed its budget: no other is walked.
    module_over: bool = false,
    /// The units that every walk of the module did so far, of every
    /// declaration and round (`Frame.tick`, `Frame.charge`). With the
    /// location table's (`Loc.Table.units`) they count against
    /// `module_budget` (kernel §8).
    module_units: u64 = 0,
    /// The module's instructions and its budget (`earnedUnits`,
    /// `moduleBudget`).
    module_size: usize = 0,
    module_budget: u64 = std.math.maxInt(u64),
    /// Per derived row of this module: its answer (`rowInfo`), and the walk
    /// it was found in (`gen`); and per row, scratch of `rowInfo`.
    row_info: []RowInfo = &.{},
    row_gen: []u32 = &.{},
    row_slot: []u32 = &.{},
    row_slot_gen: []u32 = &.{},
    gen: u32 = 1,
    /// Per declaration: an answer of `rowInfo` kept now read its contract.
    row_read: std.DynamicBitSetUnmanaged = .{},
    /// The places and steps of the place graph counted so far (`chargePlaces`).
    place_records: u64 = 0,
    /// The adapter's `var_work` counted so far (`chargePlaces`).
    var_records: u64 = 0,
    /// Per declaration: the steps that its walks took so far, in every round.
    decl_steps: []u64 = &.{},
    /// Per declaration: its budget (`declBudget`).
    decl_budget: []u64 = &.{},
    /// The budget of the declaration in work.
    decl_limit: u64 = max_walk_steps,
    /// Per instruction: what it earns (`earnedUnits`), but for its layout.
    inst_earn: []u64 = &.{},
    /// Per declaration: a walk of it gave up or passed its steps, so some
    /// of its instructions may not have been evaluated (`checkCovered`).
    incomplete: []bool = &.{},
    /// In safe builds, per instruction: a walk evaluated it, or a rule
    /// accounted for it (`Frame.noteWalked`; `checkCovered`).
    walked: std.DynamicBitSetUnmanaged = .{},
    /// Each refusal line by its instruction, cause and detail: its index in `lines` (`addRefusal`).
    refusals: std.AutoHashMapUnmanaged(RefusalKey, u32) = .empty,

    /// Whether the declaration in work passed its own budget, or the module
    /// passed its own (kernel §8).
    /// Whether no other declaration of the module is walked: one passed
    /// the budget, or a type passed the layout limit (kernel §8). Either way
    /// the module authorises no write and publishes no contract, so a walk
    /// would find nothing that is used (research report 131).
    fn stopped(m: *const Mod) bool {
        return m.module_over or m.loc.over.items.len != 0;
    }

    pub fn overBudget(m: *const Mod) bool {
        return m.steps > m.decl_limit or m.module_units +| m.loc.units > m.module_budget;
    }

    /// A walk of declaration `di` begins: its budget, what it spent before.
    /// The location table's work counts against the module alone: the table
    /// keeps what it built for every declaration, so which declaration
    /// builds a layout or a projection first depends on their order (the
    /// review of research report 138).
    fn beginDecl(m: *Mod, di: u32) void {
        m.steps = m.decl_steps[di];
        m.decl_limit = m.decl_budget[di];
        m.steps_over = m.overBudget();
    }

    /// A walk of declaration `di` ends: what it spent, for its next walk.
    fn endDecl(m: *Mod, di: u32) void {
        m.decl_steps[di] = m.steps;
        m.decl_limit = max_walk_steps;
        if (m.over_decl == null and m.loc.over.items.len != 0) m.over_decl = di;
    }

    /// The budget of declaration `di` (kernel §8): `decl_floor`, what its
    /// instructions earn (`earnedUnits`), and `layout_units` for each
    /// entry of the layout of each of them that a walk evaluates; at most
    /// `max_walk_steps`. It depends on the declaration's own instructions
    /// alone. What its layouts earn is added to the module's budget, which
    /// `earnedUnits` gave the floor and the rest of. Each declaration's is
    /// made before any walk (`checkModule`), so the module's budget does
    /// not depend on the order of the walks.
    fn declBudget(m: *Mod, di: u32) Allocator.Error!u64 {
        const d = m.bir.decls[di];
        var e: u64 = decl_floor;
        var lay: u64 = 0;
        for (d.inst_start.int()..d.inst_end.int()) |i| {
            e +|= m.inst_earn[i];
            if (!m.evaluated(@intCast(i))) continue;
            // The location table's work past the cap of every module: the
            // module passes its budget whatever the rest earns, so no more
            // of it is done (research report 145: each reference to a wide
            // value that the type check copied is read whole).
            if (m.loc.units > module_cap) break;
            const l = try m.loc.layoutOf(try m.budgetPlace(d, @intCast(i)));
            lay +|= layout_units *| m.loc.layouts.items[l].len;
        }
        m.module_budget = @min(m.module_budget +| lay, module_cap);
        return @min(e +| lay, max_walk_steps);
    }

    /// The place whose layout instruction `i` of declaration `d` earns for
    /// (`declBudget`): the place of the value that its walk makes. A
    /// reference to a local is the local's value (`Frame.evalInner`,
    /// `.local`), whose place is the local's. The reference's own type is an
    /// instance of the local's, a copy that the type check made for this
    /// reference alone, and reading each instance of a wide record whole
    /// cost the square of its width (research report 145).
    fn budgetPlace(m: *Mod, d: Bir.Decl, i: u32) Allocator.Error!PlaceId {
        if (m.tags[i] == .local and m.typeOfLocal(d, m.datas[i].lhs) != .none) return m.placeOfLocal(d, m.datas[i].lhs);
        return m.placeOfInst(i);
    }

    /// Whether instruction `i` is one that a walk evaluates: it earns `inst_units`.
    fn evaluated(m: *const Mod, i: u32) bool {
        return m.inst_earn[i] == inst_units;
    }

    /// The limit line of a type past the layout limit (`Loc.Table.over`):
    /// it names the first type cut and the declaration that met it, and
    /// points at the type's declaration when this module declares it, else
    /// at the declaration's name.
    fn overLimit(m: *Mod) Allocator.Error!Limit {
        const module_name = m.names.module_names[m.in.module];
        const p = m.loc.over.items[0];
        var token: ?u32 = if (m.over_decl) |di| m.bir.decls[di].name_token else null;
        const what: []const u8 = switch (m.places.kind(p)) {
            .ctor => blk: {
                const head = m.places.head(p);
                if (head < m.in.types.entries.len) {
                    const e = m.in.types.entries[head];
                    if (e.module.int() == m.in.module) token = m.bir.decls[e.decl.int()].name_token;
                }
                break :blk try std.fmt.allocPrint(m.arena, "`{s}`", .{m.names.type_name(m.names.ctx, head)});
            },
            .record => "a record",
            .tuple => "a tuple",
            .list => "a list",
            .dict => "a dictionary",
            .closure => "a function",
            .ref, .@"opaque", .@"var", .cross => "a type",
        };
        const by: []const u8 = if (m.over_decl) |di| try std.fmt.allocPrint(m.arena, ", met by `{s}`", .{m.names.declName(m.in.module, di)}) else "";
        return .{
            .text = try std.fmt.allocPrint(m.arena, "limit {s}: a type has more than {d} locations (a location for each path of labels through it): {s}{s}, so the checker judges no write of the module", .{ module_name, Loc.max_layout_entries, what, by }),
            .token = token,
        };
    }

    /// A limit line of declaration `di`, at its name.
    fn declLimit(m: *Mod, di: u32, text: []const u8) Allocator.Error!void {
        try m.limits.append(m.arena, .{ .text = text, .token = m.bir.decls[di].name_token });
    }

    /// The limit line of declaration `di` past a budget: the declaration's
    /// or the module's, whichever it passed.
    fn budgetLine(m: *Mod, di: u32, what: []const u8) Allocator.Error![]const u8 {
        const name = m.names.declName(m.in.module, di);
        if (m.module_units +| m.loc.units <= m.module_budget and m.decl_steps[di] > m.decl_budget[di]) {
            if (m.decl_budget[di] == max_walk_steps) return std.fmt.allocPrint(m.arena, "limit {s}: the walk{s} took more than {d} steps (a function or a value that it reaches by many paths), so the checker judges no write of the module", .{ name, what, max_walk_steps });
            return std.fmt.allocPrint(m.arena, "limit {s}: the walk{s} took more than {d} units of work (what the declaration earns), so the checker judges no write of the module", .{ name, what, m.decl_budget[di] });
        }
        return moduleLimitText(m.arena, name, m.module_budget, m.module_size);
    }

    /// What the module's instructions earn of its budget (kernel §8): each
    /// instruction that a walk evaluates earns `inst_units`, each of a type
    /// or a schema's plan `type_units`, and each of a literal what the walk
    /// of the literal can cost: `literal_units`, and `pair_units` for each
    /// pair of two lists of the literal (`deriveLinear` tests each pair of the
    /// cells of a value). So a literal does not earn what the walk of a
    /// function over a large type costs, and its elements cannot pay for the
    /// walks of other declarations (research report 136). One pass in the
    /// order of the instructions: the elements of a construction are lowered
    /// before it, and one that is not (none is, today) makes the
    /// construction no literal, which only earns more.
    fn earnedUnits(m: *Mod) Allocator.Error!u64 {
        const n = m.tags.len;
        // Per instruction: the lists of literals in it, its cells; 0 for
        // one that is no construction.
        const cells = try m.gpa.alloc(u32, n);
        defer m.gpa.free(cells);
        @memset(cells, 0);
        var lit = try std.DynamicBitSetUnmanaged.initEmpty(m.gpa, n);
        defer lit.deinit(m.gpa);
        m.inst_earn = try m.gpa.alloc(u64, n);
        @memset(m.inst_earn, 0);
        for (0..n) |i| {
            const d = m.datas[i];
            var kids: Kids = .{};
            const literal = switch (m.tags[i]) {
                .int, .float, .char, .string, .chunk, .unit, .ctor, .ext_ctor => true,
                .tuple, .list, .interp => kids.all(&lit, cells, i, m.bir.extraSlice(Bir.inlineRange(d), Inst.Index)),
                .record => blk: {
                    var all = true;
                    for (m.bir.extraSlice(Bir.inlineRange(d), Bir.Field)) |fd| all = kids.add(&lit, cells, i, fd.value.int()) and all;
                    break :blk all;
                },
                .call => blk: {
                    const args = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(d.rhs)), Inst.Index);
                    if (d.lhs < i and (m.tags[d.lhs] == .ctor or m.tags[d.lhs] == .ext_ctor)) break :blk kids.all(&lit, cells, i, args);
                    // `-1` is a call of `Basics.negate` (`Lower`).
                    // Its callee, a reference, earned `inst_units`: it is
                    // part of the literal, and earns `literal_units`.
                    if (!(d.lhs < i and args.len == 1 and args[0].int() < i)) break :blk false;
                    if (!(m.tags[args[0].int()] == .int or m.tags[args[0].int()] == .float) or !m.isNegate(d.lhs)) break :blk false;
                    if (!lit.isSet(d.lhs)) {
                        lit.set(d.lhs);
                        m.inst_earn[d.lhs] = literal_units;
                    }
                    break :blk true;
                },
                // Any other instruction is not a literal.
                .local, .top, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_value, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .record_update, .field_access, .tuple_index, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => false,
            };
            if (literal) {
                lit.set(i);
                cells[i] = kids.cells +| @intFromBool(m.tags[i] == .list);
                m.inst_earn[i] = literal_units +| pair_units *| (pairs(cells[i]) -| kids.pairs);
                continue;
            }
            // A construction that is no literal still brings the cells of
            // the literals in it together, and the walk tests their pairs.
            // It hands its cells on: a list of such constructions brings
            // theirs together again.
            if (kids.cells != 0) {
                cells[i] = kids.cells +| @intFromBool(m.tags[i] == .list);
                m.inst_earn[i] = pair_units *| (pairs(cells[i]) -| kids.pairs);
            }
            m.inst_earn[i] +|= switch (m.tags[i]) {
                .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target => type_units,
                // A `via` is a function that a walk evaluates (kernel §6.14).
                .schema_via => inst_units,
                .local, .top, .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .ext_value, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => inst_units,
            };
        }
        var earned: u64 = 0;
        for (m.inst_earn) |e| earned +|= e;
        // Each value declaration may do `decl_floor` (`declBudget`).
        for (m.bir.decls) |d| if (d.kind.isValue()) {
            earned +|= decl_floor;
        };
        return earned;
    }

    /// The elements of a construction that `earnedUnits` reads: their cells,
    /// and the pairs of them that each element earned already.
    const Kids = struct {
        cells: u32 = 0,
        pairs: u64 = 0,

        /// Whether element `e` of instruction `i` is a literal lowered
        /// before it. The cells of the literals in it, at any depth, are the
        /// construction's too, whether or not it is a literal: every element
        /// is read.
        fn add(k: *Kids, lit: *const std.DynamicBitSetUnmanaged, cells: []const u32, i: usize, e: u32) bool {
            if (!(e < i)) return false;
            k.cells +|= cells[e];
            k.pairs +|= pairs(cells[e]);
            return lit.isSet(e);
        }

        fn all(k: *Kids, lit: *const std.DynamicBitSetUnmanaged, cells: []const u32, i: usize, items: []const Inst.Index) bool {
            var every = true;
            for (items) |it| every = k.add(lit, cells, i, it.int()) and every;
            return every;
        }
    };

    /// The pairs of `n` cells.
    fn pairs(n: u32) u64 {
        const x: u64 = n;
        return x * (x -| 1) / 2;
    }

    /// Whether instruction `callee` names `Basics.negate`.
    fn isNegate(m: *const Mod, callee: u32) bool {
        const t = m.calleeOf(callee) orelse return false;
        if (t[0] >= m.names.module_names.len) return false;
        return std.mem.eql(u8, m.names.module_names[t[0]], "Basics") and std.mem.eql(u8, m.names.declName(t[0], t[1]), "negate");
    }

    // ---- types ------------------------------------------------------------------

    pub fn placeOf(m: *Mod, v: Var.Optional) Allocator.Error!PlaceId {
        // Each place and step that the place graph adds is work of the
        // module (kernel §8).
        defer m.chargePlaces();
        return m.adapter.placeOfVar(v) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // A type past a limit of the place graph: it holds anything.
            else => blk: {
                m.account.failed = null;
                break :blk m.var_place;
            },
        };
    }

    /// Count the places and steps that the place graph added since the last
    /// count against the module's budget (kernel §8): each costs about
    /// what a call of a walk costs (`call_units`), measured on the shapes
    /// of research report 130.
    fn chargePlaces(m: *Mod) void {
        const now = @as(u64, m.places.count()) + m.places.step_tab.list.len;
        m.loc.units +|= (now -| m.place_records) *| call_units;
        m.place_records = now;
        // Each store variable that the adapter closed, and each field of a
        // record it read, is work too, whether or not it
        // added a place: two instances of one wide record type add one
        // place, and each is read whole (research report 145).
        m.loc.units +|= (m.adapter.var_work -% m.var_records) *| var_units;
        m.var_records = m.adapter.var_work;
    }

    pub fn typeOfInst(m: *const Mod, inst: u32) Var.Optional {
        return if (inst < m.in.inst_type.len) m.in.inst_type[inst] else .none;
    }

    pub fn typeOfLocal(m: *const Mod, d: Bir.Decl, local: u32) Var.Optional {
        const l = d.locals_start + local;
        return if (l < m.in.local_type.len) m.in.local_type[l] else .none;
    }

    pub fn placeOfInst(m: *Mod, inst: u32) Allocator.Error!PlaceId {
        return m.placeOf(m.typeOfInst(inst));
    }

    pub fn placeOfLocal(m: *Mod, d: Bir.Decl, local: u32) Allocator.Error!PlaceId {
        return m.placeOf(m.typeOfLocal(d, local));
    }

    pub fn fnType(m: *const Mod, v: Var.Optional) ?TypeStore.Structure.Func {
        const t = v.unwrap() orelse return null;
        return switch (m.in.store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .func => |f| f,
                else => null,
            },
            else => null,
        };
    }

    /// Whether a value of type `v` is the build's markup: an application of
    /// the type the manifest names (`Options.markup_type`). The type is the
    /// platform's row; no declaration is read by its name (kernel §6.11).
    pub fn isMarkup(m: *const Mod, v: Var.Optional) bool {
        const mt = m.markup_type orelse return false;
        const t = v.unwrap() orelse return false;
        switch (m.in.store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .app => |a| {
                    const id = a.type.int();
                    if (id >= m.in.types.entries.len) return false;
                    const e = m.in.types.entries[id];
                    return e.package == .platform and e.module_name == mt.module and e.name == mt.name;
                },
                else => return false,
            },
            else => return false,
        }
    }

    /// Whether a value of type `v` is what a `view` answers: markup, or a
    /// record or tuple with markup in it whose other parts hold no cell
    /// (`Tea.Document`'s title and body). The runtime renders such a value
    /// whole, and keeps none of it (`boundary.md` §9.4.8).
    pub fn isView(m: *Mod, v: Var.Optional, depth: u32) Allocator.Error!bool {
        if (m.isMarkup(v)) return true;
        if (depth >= 4) return false;
        const t = v.unwrap() orelse return false;
        const store = m.in.store;
        const parts: []const Var = switch (store.resolvedContent(t)) {
            .structure => |s| switch (s) {
                .tuple => |r| store.vars(r),
                .record => |rec| blk: {
                    // A closed record: its fields, with no extension.
                    switch (store.resolvedContent(rec.ext)) {
                        .structure => |es| if (es != .empty_record) return false,
                        else => return false,
                    }
                    const fs = store.fields(rec.fields);
                    const out = try m.walk_arena.allocator().alloc(Var, fs.len);
                    for (out, fs) |*o, fld| o.* = fld.value;
                    break :blk out;
                },
                else => return false,
            },
            else => return false,
        };
        var markup = false;
        for (parts) |p| {
            if (try m.isView(p.toOptional(), depth + 1)) {
                markup = true;
            } else if (m.loc.layouts.items[try m.loc.layoutOf(try m.placeOf(p.toOptional()))].len != 0) return false;
        }
        return markup;
    }

    /// Whether a function parameter of type `v` is the runtime's `send`: an
    /// alias with the word `sender` (`pub sender type alias Send msg = msg →
    /// ⊤`, ownership-v2.md §2.13.5), which a platform puts on it. The word
    /// is the row; no name is read (kernel §6.11).
    pub fn isSender(m: *const Mod, v: Var.Optional) bool {
        const t = v.unwrap() orelse return false;
        const store = m.in.store;
        switch (store.content(store.find(t))) {
            .alias => |a| {
                const id = a.type.int();
                if (id >= m.in.types.entries.len) return false;
                const e = m.in.types.entries[id];
                if (e.package == .app) return false;
                return m.aliasIsSender(.{ e.module.int(), e.decl.int() }, 0);
            },
            else => return false,
        }
    }

    /// Whether the type alias at `t` has the word `sender`, or is an alias of
    /// one that has it (`Cmd.Send msg = Browser.Send msg`): its body is a
    /// reference to another alias, followed to the declaration.
    fn aliasIsSender(m: *const Mod, t: [2]u32, depth: u32) bool {
        if (depth > 8 or t[0] >= m.in.birs.len) return false;
        const owner = m.in.birs[t[0]];
        if (t[1] >= owner.decls.len) return false;
        const d = owner.decls[t[1]];
        if (d.own_kind == .sender) return true;
        var body = (d.annotation.unwrap() orelse return false).int();
        if (owner.instTag(@fromBackingInt(body)) == .type_app) body = owner.instData(@fromBackingInt(body)).lhs;
        const data = owner.instData(@fromBackingInt(body));
        return switch (owner.instTag(@fromBackingInt(body))) {
            .type_top => m.aliasIsSender(.{ t[0], data.lhs }, depth + 1),
            .ext_type => if (data.lhs < m.in.provenance.len) (if (m.in.provenance[data.lhs].typeDecl(data.rhs)) |td| m.aliasIsSender(.{ data.lhs, td.int() }, depth + 1) else false) else false,
            // Any other type is not an alias of a sender.
            .local, .top, .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_value, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_import, .type_qualified, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => false,
        };
    }

    pub fn ctorStep(m: *Mod, ordinal: u32, k: u32) Allocator.Error!Step {
        return m.places.ctorStep(m.gpa, &m.account, ordinal, k) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => blk: {
                m.account.failed = null;
                break :blk Step.level;
            },
        };
    }

    pub fn fieldRank(m: *const Mod, s: Bir.SymbolIndex) u32 {
        return m.adapter.rank(m.bir.symbol(s));
    }

    pub fn symbolText(m: *const Mod, s: Bir.SymbolIndex) []const u8 {
        return m.names.interner.slice(m.bir.symbol(s));
    }

    /// The location of a place's own cell.
    pub fn selfLoc(m: *Mod, place: PlaceId) Allocator.Error!u32 {
        return m.loc.selfLoc(place);
    }

    /// Whether a worded source at entry `from` of one layout names cells at
    /// entry `to` of the layout a word puts it in: the same location, or a
    /// wide one above it, which holds every cell below it (a `Js.Value`, or a
    /// type variable, that the result reads as a list of records). A word
    /// that matched the location alone left the locations below it with no
    /// source (kernel §3.4).
    fn holdsAt(m: *const Mod, from: Loc.Entry, to: Loc.Entry) bool {
        return to.loc == from.loc or (from.kind.wide() and m.loc.isPrefix(from.loc, to.loc));
    }

    /// Whether a word that puts the cells at location `from` (of a parameter,
    /// of an element, of a function's answer) in a result of `result`'s place,
    /// whose locations are `res_es`, leaves each cell where a reader of the
    /// result can name it: a location of the result at `from`'s place or a
    /// wide one above it holds them, and, where `from` is wide (its cells can
    /// be at any place below it), the result's place there has no part of no
    /// location (`Loc.holeAt`) unless a wide location of the result holds it
    /// whole. Where not, the location escapes: a cast reads the cells back
    /// from a part where every reader finds `outside` (kernel §6 rule 10,
    /// research report 150).
    fn placedSafely(m: *Mod, result: PlaceId, res_es: []const Loc.Entry, from: Loc.Entry) Allocator.Error!bool {
        var at = false;
        for (res_es) |re| {
            if (re.kind.wide() and m.loc.isPrefix(re.loc, from.loc)) return true;
            if (re.loc == from.loc) at = true;
        }
        if (!at) return false;
        if (!from.kind.wide()) return true;
        return !try m.loc.holeAt(result, from.loc);
    }

    /// Whether a word that puts cells anywhere in a result (`aliased`, an
    /// element no word places) leaves each where a reader can name it: a
    /// wide location of the result at its root holds every one, or the
    /// result has a location and no part of no location.
    fn placedAnywhere(m: *Mod, result: PlaceId, res_es: []const Loc.Entry) Allocator.Error!bool {
        for (res_es) |re| if (re.kind.wide() and re.loc == 0) return true;
        return res_es.len != 0 and !try m.loc.holeBelow(result);
    }

    /// Whether a word that puts a wide location `from` of the place `src`
    /// at the same path of the place `dst` reads it there at another type
    /// (`returned a → b`): a cast, which a caller can fill in with a type
    /// that hides its cells (`Contract.casts`, research report 150).
    ///
    /// The place graph has one place for every type variable (`a` and `b`
    /// are one place), so two equal places are no proof of one type: the
    /// types (`src_ty`, `dst_ty`, the parameter's and the result's at the
    /// place of the word) must be one type as well, the same variable or the
    /// same structure of the same types (`sameType`). A type the test cannot
    /// name (`null`) is another type: the pessimistic side, a cast. Before
    /// research report 151 the places alone were compared, and `returned a →
    /// b` was no cast: a caller that filled both variables with `List Int`
    /// read the row as an identity, and an answer `[a]` hid the argument at
    /// an `Int` element.
    fn castsAt(m: *Mod, src: PlaceId, dst: PlaceId, src_ty: ?Var, dst_ty: ?Var, from: Loc.Entry) Allocator.Error!bool {
        if (!from.kind.wide()) return false;
        const a = (try m.loc.placeAt(src, from.loc)) orelse return true;
        const b = (try m.loc.placeAt(dst, from.loc)) orelse return true;
        if (a != b) return true;
        const st = (try m.typeAt(src_ty, from.loc)) orelse return true;
        const dt = (try m.typeAt(dst_ty, from.loc)) orelse return true;
        return !m.sameType(st, dt, 0);
    }

    /// The type at location `loc` of a value of type `v`: its labels read
    /// one by one through an element (`elemType`), a tuple's index or a
    /// record's field. Any other label (a constructor's argument, a cell's
    /// contents, a row, a cycle's level), or a type that has no part there,
    /// is `null`: no type the test can name.
    pub fn typeAt(m: *Mod, v: ?Var, loc: u32) Allocator.Error!?Var {
        var t = v orelse return null;
        if (loc == 0) return t;
        var ls: std.ArrayList(u64) = .empty;
        defer ls.deinit(m.gpa);
        try m.loc.labels(loc, &ls, m.gpa);
        const store = m.in.store;
        for (ls.items) |w| {
            const l: Loc.Label = @bitCast(w);
            if (l.cyc) return null;
            _, const c = store.resolved(t);
            const s = switch (c) {
                .structure => |s| s,
                .flex, .rigid, .alias, .err => return null,
            };
            t = switch (l.kind) {
                .elem => m.elemType(t) orelse return null,
                .index => switch (s) {
                    .tuple => |r| blk: {
                        const xs = store.vars(r);
                        if (l.payload >= xs.len) return null;
                        break :blk xs[l.payload];
                    },
                    .unit, .empty_record, .func, .app, .record => return null,
                },
                .field => switch (s) {
                    .record => |r| blk: {
                        for (store.fields(r.fields)) |fd| {
                            const sym = @backingInt(fd.name);
                            if (sym < m.in.ranks.len and m.in.ranks[sym] == l.payload) break :blk fd.value;
                        }
                        return null;
                    },
                    .unit, .empty_record, .func, .app, .tuple => return null,
                },
                .ctor_arg => m.ctorArgType(t, l.head, l.payload >> 12, l.payload & 0xfff) orelse return null,
                .contents, .row, .member, .env, .slot, .fslot => return null,
            };
        }
        return t;
    }

    /// Whether `aliased` puts the location `loc` of a parameter of type
    /// `pty` at a type variable of the result (of type `rty`, entries
    /// `res_es`) whose type is not the location's: the word places it at any
    /// place of the result, and a type variable is filled in by the caller,
    /// so the JavaScript can answer it below the variable's place, where the
    /// caller's type has a part of no location (`Contract.casts`). An opaque
    /// result (`Js.array : aliased elements → fresh Value`) is no type
    /// variable: a `Js.Value` is read back as what it was made of
    /// (`Frame.madeOfParts`).
    fn aliasedCasts(m: *Mod, pty: Var, loc: u32, rty: ?Var, res_es: []const Loc.Entry) Allocator.Error!bool {
        for (res_es) |re| {
            if (re.kind != .@"var") continue;
            const a = (try m.typeAt(pty, loc)) orelse return true;
            const b = (try m.typeAt(rty, re.loc)) orelse return true;
            if (!m.sameType(a, b, 0)) return true;
        }
        return false;
    }

    /// The type at the path `path` of a root of type `t` whose own path is
    /// `root` (a path of `Loc.paths`, below it by steps): each step read as
    /// `typeAt` reads a label (an element, a tuple's index, a record's field
    /// by its rank). `null` past any other step, or where the path is not
    /// below `root`.
    pub fn typeAtPath(m: *Mod, t: Var, root: u32, path: u32) ?Var {
        var steps: [32]Step = undefined;
        var k: usize = 0;
        var p = path;
        while (p != root) {
            if (k == steps.len) return null;
            const pp = m.loc.paths.items[p];
            if (pp.depth == 0) return null;
            steps[k] = Step.fromWord(pp.step);
            k += 1;
            p = pp.parent;
        }
        const store = m.in.store;
        var cur = t;
        while (k > 0) {
            k -= 1;
            const s = steps[k];
            _, const c = store.resolved(cur);
            const st = switch (c) {
                .structure => |x| x,
                .flex, .rigid, .alias, .err => return null,
            };
            cur = switch (s.kind) {
                .elem => m.elemType(cur) orelse return null,
                .index => switch (st) {
                    .tuple => |r| blk: {
                        const xs = store.vars(r);
                        if (s.payload >= xs.len) return null;
                        break :blk xs[s.payload];
                    },
                    .unit, .empty_record, .func, .app, .record => return null,
                },
                .field => switch (st) {
                    .record => |r| blk: {
                        for (store.fields(r.fields)) |fd| {
                            const sym = @backingInt(fd.name);
                            if (sym < m.in.ranks.len and m.in.ranks[sym] == s.payload) break :blk fd.value;
                        }
                        return null;
                    },
                    .unit, .empty_record, .func, .app, .tuple => return null,
                },
                .ctor_arg => blk: {
                    const ca = m.places.ctorArgOf(s);
                    const head = switch (st) {
                        .app => |ap| ap.type.int(),
                        .unit, .empty_record, .func, .tuple, .record => return null,
                    };
                    break :blk m.ctorArgType(cur, head, ca[0], ca[1]) orelse return null;
                },
                .contents, .env, .slot, .level, .row => return null,
            };
        }
        return cur;
    }

    /// The type of argument `arg` of constructor `ctor` (its ordinal) of the
    /// type `t`, an application of the custom type `head`: the application's
    /// argument where the declaration writes the constructor's argument as
    /// one of the type's parameters (`Just a` of `Maybe a`, `Node a …` of
    /// `Tree a`); `null` for any other argument, which this test does not
    /// read (the pessimistic side).
    fn ctorArgType(m: *Mod, t: Var, head: u32, ctor: u32, arg: u32) ?Var {
        const store = m.in.store;
        _, const c = store.resolved(t);
        const ap = switch (c) {
            .structure => |s| switch (s) {
                .app => |x| x,
                .unit, .empty_record, .func, .tuple, .record => return null,
            },
            .flex, .rigid, .alias, .err => return null,
        };
        if (ap.type.int() != head or head >= m.in.types.entries.len) return null;
        const e = m.in.types.entries[head];
        if (e.kind != .adt or e.module.int() >= m.in.birs.len) return null;
        const bir = m.in.birs[e.module.int()];
        const ctors = bir.declCtors(bir.decl(e.decl));
        if (ctor >= ctors.len) return null;
        const cargs = bir.extraSlice(.{ .start = ctors[ctor].args_start, .end = ctors[ctor].args_end }, Inst.Index);
        if (arg >= cargs.len) return null;
        const term = cargs[arg];
        if (bir.instTag(term) != .type_var) return null;
        const p = Bir.TypeVarInfo.unpack(bir.instData(term).rhs).param;
        if (p == Bir.TypeVarInfo.param_none) return null;
        const xs = store.vars(ap.args);
        return if (p < xs.len) xs[p] else null;
    }

    /// Whether the types `a` and `b` are one type: one variable of the
    /// store, or one structure whose parts are one type each. An alias is
    /// read through (`resolved`); a record, an error or a structure deeper
    /// than 16 is another type (the pessimistic side, `castsAt`).
    pub fn sameType(m: *Mod, a: Var, b: Var, depth: u32) bool {
        if (depth > 16) return false;
        const store = m.in.store;
        const ra, const ca = store.resolved(a);
        const rb, const cb = store.resolved(b);
        if (ra == rb) return true;
        const sa = switch (ca) {
            .structure => |s| s,
            .flex, .rigid, .alias, .err => return false,
        };
        const sb = switch (cb) {
            .structure => |s| s,
            .flex, .rigid, .alias, .err => return false,
        };
        switch (sa) {
            .unit => return sb == .unit,
            .empty_record => return sb == .empty_record,
            .func => |fa| {
                const fb = switch (sb) {
                    .func => |x| x,
                    else => return false,
                };
                return m.sameVars(store.vars(fa.params), store.vars(fb.params), depth) and m.sameType(fa.result, fb.result, depth + 1);
            },
            .app => |aa| {
                const ab = switch (sb) {
                    .app => |x| x,
                    else => return false,
                };
                return aa.type == ab.type and m.sameVars(store.vars(aa.args), store.vars(ab.args), depth);
            },
            .tuple => |ta| {
                const tb = switch (sb) {
                    .tuple => |x| x,
                    else => return false,
                };
                return m.sameVars(store.vars(ta), store.vars(tb), depth);
            },
            .record => return false,
        }
    }

    fn sameVars(m: *Mod, xs: []const Var, ys: []const Var, depth: u32) bool {
        if (xs.len != ys.len) return false;
        for (xs, ys) |x, y| if (!m.sameType(x, y, depth + 1)) return false;
        return true;
    }

    /// The element type of a sequence type (`List a`, `Builder a`: an
    /// application of one argument), or `null`.
    /// Whether type `t` is a keyed collection (`Bir.OwnKind.keyed`, kernel §12).
    fn keyedType(m: *Mod, t: anytype) bool {
        if (t.int() >= m.in.types.entries.len) return false;
        const e = m.in.types.entries[t.int()];
        if (e.kind != .foreign) return false;
        return m.in.birs[e.module.int()].decl(e.decl).own_kind == .keyed;
    }

    fn elemType(m: *Mod, v: ?Var) ?Var {
        const t = v orelse return null;
        const store = m.in.store;
        _, const c = store.resolved(t);
        switch (c) {
            .structure => |s| switch (s) {
                .app => |ap| {
                    const args = store.vars(ap.args);
                    if (args.len == 1) return args[0];
                    // A keyed collection's elements are its values, the
                    // second argument (kernel §12).
                    if (args.len == 2 and m.keyedType(ap.type)) return args[1];
                    return null;
                },
                .unit, .empty_record, .func, .tuple, .record => return null,
            },
            .flex, .rigid, .alias, .err => return null,
        }
    }

    /// The type of the answer of the function type `v`, or `null`.
    fn answerType(m: *Mod, v: Var) ?Var {
        const ft = m.fnType(v.toOptional()) orelse return null;
        return ft.result;
    }

    /// Whether `place` is a record's.
    pub fn isRecordPlace(m: *const Mod, place: PlaceId) bool {
        return m.places.kind(place) == .record;
    }

    /// The allocation site number of the site named `name` in a contract of
    /// this module (kernel §4.2): the same number for the same name, in every
    /// round of a group.
    pub fn siteId(m: *Mod, name: u64) Allocator.Error!u16 {
        const got = try m.sites.getOrPut(m.gpa, name);
        if (!got.found_existing) got.value_ptr.* = @intCast(@min(m.sites.count() - 1, std.math.maxInt(u16)));
        return got.value_ptr.*;
    }

    pub fn isDraft(m: *const Mod, c: *const Contract.Contract) bool {
        return m.drafts.contains(@intFromPtr(c));
    }

    // ---- names of the program --------------------------------------------------

    pub const CtorInfo = struct { ordinal: u32, arity: u32 };

    /// The module and the constructor that the reference `ref` names.
    fn ctorAt(m: *const Mod, ref: u32) ?[2]u32 {
        const d = m.datas[ref];
        const at: [2]u32 = switch (m.tags[ref]) {
            .ctor => .{ m.in.module, d.lhs },
            .ext_ctor => if (d.lhs < m.in.provenance.len and d.rhs < m.in.provenance[d.lhs].ctor_index.len) .{ d.lhs, m.in.provenance[d.lhs].ctor_index[d.rhs] } else return null,
            // No other instruction names a constructor.
            .local, .top, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_value, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => return null,
        };
        if (at[0] >= m.in.birs.len or at[1] >= m.in.birs[at[0]].ctors.len) return null;
        return at;
    }

    pub fn ctorInfo(m: *const Mod, ref: u32) ?CtorInfo {
        const at = m.ctorAt(ref) orelse return null;
        const owner = m.in.birs[at[0]];
        const c = owner.ctors[at[1]];
        return .{ .ordinal = at[1] - owner.decl(c.decl).ctors_start, .arity = @backingInt(c.args_end) - @backingInt(c.args_start) };
    }

    /// The step from a value that the constructor `ref` makes to its
    /// argument `k`: the constructor's argument, or, for a record alias's
    /// constructor, the field that its argument `k` is (the fields in the
    /// order the alias writes them; backend.md §4: the constructor builds
    /// the record). Null when neither describes it.
    pub fn ctorArgStep(m: *Mod, ref: u32, place: PlaceId, k: u32) Allocator.Error!?Step {
        const info = m.ctorInfo(ref) orelse return null;
        if (k >= info.arity) return null;
        switch (m.places.kind(place)) {
            .ctor => return try m.ctorStep(info.ordinal, k),
            .record => return m.recordAliasStep(ref, k),
            // No step is known from any other place.
            .tuple, .list, .dict, .ref, .closure, .@"opaque", .@"var", .cross => return null,
        }
    }

    /// Whether the constructor `ref` is a record alias's, which builds a
    /// record and matches one (backend.md §4), whatever place it is read at.
    pub fn isRecordAliasCtor(m: *const Mod, ref: u32) bool {
        const at = m.ctorAt(ref) orelse return false;
        const owner = m.in.birs[at[0]];
        const d = owner.decl(owner.ctors[at[1]].decl);
        if (d.kind != .type_alias) return false;
        const body = d.annotation.unwrap() orelse return false;
        return owner.instTag(body) == .type_record;
    }

    /// The field step of a record alias's constructor `ref`'s argument `k`:
    /// the field that the alias writes `k`-th. Null when `ref` is no record
    /// alias's constructor, or the alias's fields are not its arguments.
    pub fn recordAliasStep(m: *const Mod, ref: u32, k: u32) ?Step {
        const info = m.ctorInfo(ref) orelse return null;
        if (k >= info.arity) return null;
        const at = m.ctorAt(ref).?;
        const owner = m.in.birs[at[0]];
        const body = owner.decl(owner.ctors[at[1]].decl).annotation.unwrap() orelse return null;
        if (owner.instTag(body) != .type_record) return null;
        const fields = owner.extraSlice(Bir.inlineRange(owner.instData(body)), Bir.Field);
        if (fields.len != info.arity) return null;
        return .{ .kind = .field, .payload = @intCast(m.adapter.rank(owner.symbol(fields[k].name))) };
    }

    /// The step from the scrutinee of a `try` to the value that it has when
    /// it succeeds: the argument of `Ok` or `Just`, each its type's first
    /// constructor (language.md §6.6). Null for another type.
    pub fn trySuccess(m: *Mod, scrut: u32) Allocator.Error!?Step {
        const at = try m.placeOfInst(scrut);
        if (m.places.kind(at) != .ctor) return null;
        const head = m.places.head(at);
        const wk = m.in.types.well_known;
        if (head != wk.result.int() and head != wk.maybe.int()) return null;
        return try m.ctorStep(0, 0);
    }

    /// The declaration a reference runs, aliases followed.
    pub fn calleeOf(m: *const Mod, inst: u32) ?[2]u32 {
        const d = m.datas[inst];
        var t: [2]u32 = switch (m.tags[inst]) {
            .top => .{ m.in.module, d.lhs },
            .ext_value => blk: {
                if (d.lhs >= m.in.provenance.len) return null;
                const decl = m.in.provenance[d.lhs].valueDecl(d.rhs) orelse return null;
                break :blk .{ d.lhs, decl.int() };
            },
            // No other instruction names a declaration to call.
            .local, .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => return null,
        };
        var budget: u32 = 16;
        while (budget > 0) : (budget -= 1) t = Prepass.aliasStep(m.in.birs, m.in.provenance, t) orelse break;
        return t;
    }

    pub fn methodTarget(m: *const Mod, inst: u32) ?[2]u32 {
        const dt = m.in.dispatch orelse return null;
        const site = dt.siteOf(@fromBackingInt(inst)) orelse return null;
        const ti = site.callee.unwrap() orelse return null;
        return switch (dt.term(ti)) {
            .top => |u| .{ m.in.module, u.decl.int() },
            .ext => |u| if (m.in.provenance.len > u.module.int()) (if (m.in.provenance[u.module.int()].valueDecl(@backingInt(u.value))) |d| .{ u.module.int(), d.int() } else null) else null,
            // No other term names a declaration.
            .param, .derived, .ext_derived, .primitive, .undetermined, .field, .identity, .text, .codec => null,
        };
    }

    pub fn isListAppend(m: *const Mod, inst: u32) bool {
        const dt = m.in.dispatch orelse return false;
        return dt.isListAppend(@fromBackingInt(inst)) or dt.isListAppend(@fromBackingInt(m.datas[inst].lhs));
    }

    pub fn spreadOf(m: *const Mod, d: Bir.Decl, inst: u32) ?Bir.Spread {
        if (inst >= m.spread_root.bit_length or !m.spread_root.isSet(inst)) return null;
        for (m.bir.spreads(d)) |s| if (s.root == inst) return s;
        return null;
    }

    fn declOf(m: *const Mod, t: [2]u32) ?Bir.Decl {
        if (t[0] >= m.in.birs.len or t[1] >= m.in.birs[t[0]].decls.len) return null;
        return m.in.birs[t[0]].decls[t[1]];
    }

    /// Where a function of an entry's record has the model, read off the
    /// entry's declared type (kernel §6.13): the model is the type variable
    /// of `update`'s last parameter.
    pub const EntryField = struct {
        name: InternPool.Symbol,
        /// The field's declared type is a function, of this many parameters.
        is_fn: bool,
        arity: u32 = 0,
        /// The parameter that is the model, or `none`.
        model_param: u32 = none,
        /// Where the answer has the model: `none` (it has none), `whole` (the
        /// answer is the model), `index` (the item `index` of a tuple).
        answer: enum { none, whole, index } = .none,
        index: u32 = 0,
        /// The model is in a parameter or the answer in another shape: no
        /// fact says where, and the entry has none of its lists `own`.
        unknown: bool = false,
    };

    /// The fields of the record that the entry `t` takes (its first
    /// parameter), or null where the declared type is not one that this
    /// reads (no fact: the caller takes no location as `own`).
    pub fn entryShape(m: *Mod, t: [2]u32) Allocator.Error!?[]const EntryField {
        const d = m.declOf(t) orelse return null;
        const bir = m.in.birs[t[0]];
        const ann = d.annotation.unwrap() orelse return null;
        if (bir.instTag(ann) != .type_fn) return null;
        const ps = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(ann).lhs)), Inst.Index);
        if (ps.len == 0 or bir.instTag(ps[0]) != .type_record) return null;
        const fields = bir.extraSlice(Bir.inlineRange(bir.instData(ps[0])), Bir.Field);
        const interner = m.in.interner orelse return null;
        const update_sym = interner.find("update") orelse return null;
        // The model: the type variable of `update`'s last parameter.
        var model: ?InternPool.Symbol = null;
        for (fields) |fd| if (bir.symbol(fd.name) == update_sym and bir.instTag(fd.value) == .type_fn) {
            const up = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(fd.value).lhs)), Inst.Index);
            if (up.len != 0 and bir.instTag(up[up.len - 1]) == .type_var) model = bir.symbol(@fromBackingInt(bir.instData(up[up.len - 1]).lhs));
        };
        const mv = model orelse return null;
        const out = try m.walk_arena.allocator().alloc(EntryField, fields.len);
        for (fields, out) |fd, *o| {
            o.* = .{ .name = bir.symbol(fd.name), .is_fn = bir.instTag(fd.value) == .type_fn };
            if (!o.is_fn) {
                if (try m.mentionsVar(bir, fd.value, mv)) o.unknown = true;
                continue;
            }
            const fps = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(fd.value).lhs)), Inst.Index);
            o.arity = @intCast(fps.len);
            for (fps, 0..) |p, k| {
                if (isVar(bir, p, mv)) {
                    if (o.model_param != none) o.unknown = true;
                    o.model_param = @intCast(k);
                } else if (try m.mentionsVar(bir, p, mv)) o.unknown = true;
            }
            const r: Inst.Index = @fromBackingInt(bir.instData(fd.value).rhs);
            if (isVar(bir, r, mv)) {
                o.answer = .whole;
            } else if (bir.instTag(r) == .type_tuple) {
                for (bir.extraSlice(Bir.inlineRange(bir.instData(r)), Inst.Index), 0..) |item, k| {
                    if (isVar(bir, item, mv)) {
                        if (o.answer != .none) o.unknown = true;
                        o.answer = .index;
                        o.index = @intCast(k);
                    } else if (try m.mentionsVar(bir, item, mv)) o.unknown = true;
                }
            } else if (try m.mentionsVar(bir, r, mv)) o.unknown = true;
        }
        return out;
    }

    fn isVar(bir: *const Bir, t: Inst.Index, v: InternPool.Symbol) bool {
        return bir.instTag(t) == .type_var and bir.symbol(@fromBackingInt(bir.instData(t).lhs)) == v;
    }

    /// Whether the type written at `t` names the type variable `v`.
    fn mentionsVar(m: *Mod, bir: *const Bir, t: Inst.Index, v: InternPool.Symbol) Allocator.Error!bool {
        if (isVar(bir, t, v)) return true;
        var ops: std.ArrayList(Inst.Index) = .empty;
        defer ops.deinit(m.gpa);
        try bir.operands(m.gpa, t, &ops);
        for (ops.items) |o| if (try m.mentionsVar(bir, o, v)) return true;
        return false;
    }

    pub fn isWorded(m: *const Mod, t: [2]u32) bool {
        const d = m.declOf(t) orelse return false;
        return m.in.birs[t[0]].ownSlotsV2(d).len != 0;
    }

    /// Whether the build emits a saturated call of declaration `t` as its
    /// one argument: `Js.from` and `Js.to` of the core package, which the
    /// backend writes as nothing (`js/JsIntrinsic.zig`, the same key: the
    /// core package, the module `Js`, the declaration's name; a module of
    /// another package named `Js` is an ordinary module). The call's value
    /// is the argument itself, a fact of the code the build writes, which no
    /// word says: `returned a → Value` is as true of a row that answers
    /// `[a]` (kernel §3.4, *What a value was made from*; research report 151).
    pub fn emitsArgument(m: *const Mod, t: [2]u32) bool {
        if (t[0] == none or !m.in.isCore(t[0]) or t[0] >= m.names.module_names.len) return false;
        if (!std.mem.eql(u8, m.names.module_names[t[0]], "Js")) return false;
        if (m.declOf(t) == null) return false;
        const name = m.names.declName(t[0], t[1]);
        return std.mem.eql(u8, name, "from") or std.mem.eql(u8, name, "to");
    }

    /// Whether the declaration is a function: a reference to it is a function value.
    pub fn isFunction(m: *Mod, t: [2]u32) Allocator.Error!bool {
        const d = m.declOf(t) orelse return false;
        if (!d.kind.isValue()) return false;
        if (d.params != 0) return true;
        const body = d.body.unwrap() orelse return false;
        return m.in.birs[t[0]].instTag(body) == .lambda;
    }

    /// The contract of declaration `t`, or null when nothing is known of it.
    pub fn declContract(m: *Mod, t: [2]u32) Allocator.Error!?*const Contract.Contract {
        if (t[0] != m.in.module) {
            if (t[0] >= m.readers.len) return null;
            if (m.readers[t[0]] == null) {
                const from = m.shared.published[t[0]] orelse return null;
                m.readers[t[0]] = try Contract.Reader.init(m.arena, from);
            }
            return m.readers[t[0]].?.contract(m.gpa, m.arena, &m.loc, t[1]);
        }
        const d = m.bir.decls[t[1]];
        if (!d.kind.isValue()) return null;
        if (m.bir.ownSlotsV2(d).len != 0) {
            if (!m.worded_done[t[1]]) {
                m.worded_done[t[1]] = true;
                m.contracts[t[1]] = try m.wordedContract(t[1]);
                m.contractChanged(t[1]);
            }
            return m.contracts[t[1]];
        }
        return m.contracts[t[1]];
    }

    // ---- code that the walk does not follow --------------------------------------

    /// What the code that dispatch edge `e` names can do with a value it is
    /// handed (kernel §6.11): write it, keep it, or nothing that a contract
    /// says (`no_contract`: unknown code, which keeps what it is handed).
    /// The code is called by code that the walk does not follow — a
    /// function the compiler derives, or code handed evidence — so the fact
    /// is read off the callee's contract, never off its name, and a missing
    /// fact is the pessimistic one: another module's derived method with no
    /// published fact can write and keep.
    pub fn edgeEffect(m: *Mod, e: Edges.Edge) Allocator.Error!Contract.Effect {
        const target: [2]u32 = switch (e) {
            .top => |d| .{ m.in.module, d },
            .ext => |x| blk: {
                if (x.module.int() >= m.in.provenance.len) return .{ .no_contract = true };
                const d = m.in.provenance[x.module.int()].valueDecl(x.value) orelse return .{ .no_contract = true };
                break :blk .{ x.module.int(), d.int() };
            },
            // This module's row: its body is walked with the edges (`through_rows`).
            .derived => return .{},
            .ext_derived => |u| {
                const owner = m.in.types.entries[@backingInt(u.type)].module;
                for ([_]u32{ u.module.int(), owner.int() }) |mi| {
                    if (mi >= m.shared.published.len) continue;
                    const p = m.shared.published[mi] orelse continue;
                    if (Contract.derivedFact(p, @backingInt(u.type), @backingInt(u.kind))) |x| return x;
                }
                return .{ .writes = true, .keeps = true, .no_contract = true };
            },
            // The compiler's own comparisons and codecs: they read their
            // operands; what they call is an edge of its own.
            .primitive, .undetermined, .codec => return .{},
        };
        // A function's contract says what a call of it does.
        if (try m.declContract(target)) |c| if (c.arity != 0) return .{ .writes = c.writes(), .keeps = c.escapes(), .rewrites = Contract.rewritesFn(c) };
        // A constant's contract says what its value holds, not what a call
        // of it does: a method written `pub eq = keeper` has no fact here,
        // nor has a function whose walk gave up. Only a declaration whose
        // own type is no function names no code (research report 129 §6).
        if (try m.isFunction(target)) return .{ .no_contract = true };
        if (m.valueIsFunction(target)) |is_fn| if (!is_fn) return .{};
        return .{ .no_contract = true };
    }

    /// Whether the value of declaration `t` is a function, by its type
    /// scheme; null where this module has no scheme of it (another module).
    fn valueIsFunction(m: *const Mod, t: [2]u32) ?bool {
        if (t[0] != m.in.module or t[1] >= m.in.decl_scheme.len) return null;
        const scheme = m.in.decl_scheme[t[1]];
        if (scheme == .none) return null;
        return m.fnType(scheme) != null;
    }

    /// The text of a refusal of evidence with effect `x` (`Frame.evidence`).
    pub fn evidenceText(x: Contract.Effect) []const u8 {
        if (x.writes) return "a function that writes its parameter is handed as evidence";
        if (x.keeps) return "a function that keeps its parameter is handed as evidence";
        if (x.rewrites) return "a function that changes a value after it handed it to a function parameter is handed as evidence";
        return "a function with no contract is handed as evidence";
    }

    /// What the code that the terms `roots` name can do, through the body
    /// of each derived row of this module that they name, at any depth: the
    /// join of the effects of their edges (`edgeEffect`), and which texts of
    /// a refusal of evidence those edges make (`evidenceText`, a bit each).
    /// A row's answer is kept while the module's contracts stay the same
    /// (`rowInfo`), so a row's body is read once for each set of contracts,
    /// not once for each term that names it (kernel §8).
    pub fn termsInfo(m: *Mod, roots: []const Dispatch.TermIndex) Allocator.Error!RowInfo {
        const dt = m.in.dispatch orelse return .{};
        const arena = m.walk_arena.allocator();
        var edges: std.ArrayList(Edges.Edge) = .empty;
        defer edges.deinit(arena);
        try Edges.termsEdges(&edges, arena, dt, roots, false);
        m.loc.units +|= edges.items.len * Loc.lookup_units;
        var r: RowInfo = .{};
        for (edges.items) |e| switch (e) {
            .derived => |j| if (j < dt.derived.len) r.add(try m.rowInfo(j)),
            .top, .ext, .ext_derived, .primitive, .undetermined, .codec => r.addEffect(try m.rowEdgeEffect(e)),
        };
        return r;
    }

    /// `termsInfo` of the body of derived row `j`, kept until a contract of
    /// a declaration of the module that it read changes (`contractChanged`):
    /// `edgeEffect` reads nothing else that changes. The rows that `j` reaches and that are not kept are
    /// solved together, a row at a time from a worklist: a row's answer only
    /// grows, by at most eight bits, so each row is read again at most
    /// eight times for each row that names it.
    fn rowInfo(m: *Mod, j: u32) Allocator.Error!RowInfo {
        if (m.row_gen[j] == m.gen) return m.row_info[j];
        // Past the budget no walk goes on (kernel §8): the row is code
        // that writes and keeps, and the declaration gives up.
        if (m.overBudget()) {
            var x: RowInfo = .{};
            x.addEffect(.{ .writes = true, .keeps = true, .no_contract = true });
            return x;
        }
        const dt = m.in.dispatch.?;
        const arena = m.walk_arena.allocator();
        var rows: std.ArrayList(u32) = .empty;
        defer rows.deinit(arena);
        // Per row of `rows`: its own edges' answer, and the rows it names.
        var direct: std.ArrayList(RowInfo) = .empty;
        defer direct.deinit(arena);
        var deps: std.ArrayList([]const u32) = .empty;
        defer deps.deinit(arena);
        var edges: std.ArrayList(Edges.Edge) = .empty;
        defer edges.deinit(arena);
        var names: std.ArrayList(u32) = .empty;
        defer names.deinit(arena);
        try rows.append(arena, j);
        m.row_slot[j] = 0;
        m.row_slot_gen[j] = m.gen;
        var next: usize = 0;
        while (next < rows.items.len) : (next += 1) {
            // Past the budget the rows are not read on (kernel §8). The
            // slots of this call's rows are let go, so no later call reads
            // a slot of a list it did not build.
            if (m.overBudget()) {
                for (rows.items) |k| m.row_slot_gen[k] = m.gen - 1;
                var x: RowInfo = .{};
                x.addEffect(.{ .writes = true, .keeps = true, .no_contract = true });
                return x;
            }
            const r = rows.items[next];
            edges.clearRetainingCapacity();
            try Edges.termsEdges(&edges, arena, dt, dt.argsAt(dt.derived[r].body), false);
            m.loc.units +|= call_units + edges.items.len * Loc.lookup_units;
            var own: RowInfo = .{};
            names.clearRetainingCapacity();
            for (edges.items) |e| switch (e) {
                .derived => |k| {
                    if (k >= dt.derived.len) continue;
                    if (m.row_gen[k] == m.gen) {
                        own.add(m.row_info[k]);
                        continue;
                    }
                    if (m.row_slot_gen[k] != m.gen) {
                        m.row_slot_gen[k] = m.gen;
                        m.row_slot[k] = @intCast(rows.items.len);
                        try rows.append(arena, k);
                    }
                    try names.append(arena, m.row_slot[k]);
                },
                .top, .ext, .ext_derived, .primitive, .undetermined, .codec => own.addEffect(try m.rowEdgeEffect(e)),
            };
            try direct.append(arena, own);
            try deps.append(arena, try arena.dupe(u32, names.items));
        }
        // The rows that name each row, and the least answer of all of them.
        const n = rows.items.len;
        const named_by = try arena.alloc(std.ArrayList(u32), n);
        @memset(named_by, .empty);
        for (deps.items, 0..) |ds, i| for (ds) |d| try named_by[d].append(arena, @intCast(i));
        const got = try arena.dupe(RowInfo, direct.items);
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(arena);
        for (0..n) |i| try work.append(arena, @intCast(i));
        while (work.pop()) |i| {
            var x = direct.items[i];
            for (deps.items[i]) |d| x.add(got[d]);
            m.loc.units +|= 1 + deps.items[i].len;
            if (RowInfo.eql(x, got[i])) continue;
            got[i] = x;
            for (named_by[i].items) |up| try work.append(arena, up);
        }
        for (rows.items, got) |r, x| {
            m.row_info[r] = x;
            m.row_gen[r] = m.gen;
        }
        return m.row_info[j];
    }

    /// The contract of declaration `di` changed: the answers of `rowInfo`
    /// kept so far are dropped if one read the old one (`row_read`).
    pub fn contractChanged(m: *Mod, di: u32) void {
        if (!m.row_read.isSet(di)) return;
        m.gen += 1;
        m.row_read.unsetAll();
    }

    /// `edgeEffect` for `rowInfo` and `termsInfo`: a declaration of this
    /// module that it reads is noted (`contractChanged`).
    /// The bit is set after the read: a first read of a worded contract
    /// changes it (`declContract`), and that change must not clear the bits
    /// of the reads before it.
    fn rowEdgeEffect(m: *Mod, e: Edges.Edge) Allocator.Error!Contract.Effect {
        const x = try m.edgeEffect(e);
        switch (e) {
            .top => |d| if (d < m.row_read.bit_length) m.row_read.set(d),
            // Only a declaration of this module has a read bit.
            .ext, .derived, .ext_derived, .primitive, .undetermined, .codec => {},
        }
        return x;
    }

    /// For each derived method of a nominal type that this module emits:
    /// what the methods it calls, at any depth, can do (`edgeEffect`). A
    /// row's evidence parameters are judged where it is used. Each row is
    /// read once (`rowInfo`), with every contract of the module known.
    fn derivedFacts(m: *Mod) Allocator.Error![]const Contract.DerivedFact {
        const dt = m.in.dispatch orelse return &.{};
        var out: std.ArrayList(Contract.DerivedFact) = .empty;
        for (dt.derived, 0..) |row, ri| {
            const t = switch (row.shape) {
                .nominal => |id| id,
                .record, .tuple, .unit => continue,
            };
            const x = (try m.rowInfo(@intCast(ri))).effect;
            try out.append(m.arena, .{ .type = @backingInt(t), .kind = @backingInt(row.kind), .effect = x });
        }
        return out.items;
    }

    // ---- the signature of a declaration ------------------------------------------

    const Sig = struct { params: []PlaceId, result: PlaceId, vars: []const Var, fnt: ?TypeStore.Structure.Func };

    /// The type of a signature's result, or `null`.
    fn sigResult(sig: Sig) ?Var {
        return if (sig.fnt) |ft| ft.result else null;
    }

    fn sigOf(m: *Mod, di: u32) Allocator.Error!?Sig {
        const scheme: Var.Optional = if (di < m.in.decl_scheme.len) m.in.decl_scheme[di] else .none;
        const ft = m.fnType(scheme) orelse return null;
        const vars = m.in.store.vars(ft.params);
        const params = try m.walk_arena.allocator().alloc(PlaceId, vars.len);
        for (params, vars) |*p, v| p.* = try m.placeOf(v.toOptional());
        return .{ .params = params, .result = try m.placeOf(ft.result.toOptional()), .vars = vars, .fnt = ft };
    }

    /// The contract with no flag and no source: where a group's rounds start.
    fn bottom(m: *Mod, di: u32) Allocator.Error!?*const Contract.Contract {
        const d = m.bir.decls[di];
        const sig = (try m.sigOf(di)) orelse return null;
        if (sig.params.len != d.params) {
            // A function value declared with no parameter: its contract is
            // the lambda's that its body is (`walkDecl`), so its rounds start
            // where a function of the lambda's parameters does. With no
            // contract at the start, a member walked before it read it as
            // unknown code, and contracts only grow: whether a parameter
            // escaped depended on the order of the walk (research report 141).
            const body = d.body.unwrap() orelse return null;
            if (d.params != 0 or m.tags[body.int()] != .lambda) return null;
            const lparams = m.bir.extraSlice(m.bir.subRange(@fromBackingInt(m.datas[body.int()].lhs)), Bir.Inst.Index);
            if (lparams.len != sig.params.len) return null;
        }
        const tys = try m.walk_arena.allocator().alloc(Var.Optional, sig.vars.len);
        for (tys, sig.vars) |*t, v| t.* = v.toOptional();
        return m.bottomContract(sig.params, tys, sig.result);
    }

    /// `emptyContract`, and for each parameter of a function type the
    /// contract of a function that the body does nothing with. A parameter
    /// with no function contract is one that the checker does not follow: a
    /// caller hands it a function as to the default. So the rounds of a
    /// group, whose contracts only grow, must not start from that.
    pub fn bottomContract(m: *Mod, params: []const PlaceId, tys: []const Var.Optional, result: PlaceId) Allocator.Error!*Contract.Contract {
        const c = try m.emptyContract(params, result);
        const fns = @constCast(c.fns);
        for (fns, tys) |*f, ty| f.* = try m.bottomFn(ty);
        return c;
    }

    /// The contract of a function parameter of type `ty` that its owner does nothing with; null when `ty` is no function type.
    fn bottomFn(m: *Mod, ty: Var.Optional) Allocator.Error!?*const Contract.Fn {
        const ft = m.fnType(ty) orelse return null;
        const pvars = m.in.store.vars(ft.params);
        const arity: u32 = @intCast(pvars.len);
        const layouts = try m.arena.alloc(u32, arity + 1);
        const off = try m.arena.alloc(u32, arity + 1);
        var total: u32 = 0;
        for (pvars, 0..) |pv, k| {
            layouts[k] = try m.loc.layoutOf(try m.placeOf(pv.toOptional()));
            off[k] = total;
            total += @intCast(m.loc.layouts.items[layouts[k]].len);
        }
        off[arity] = total;
        layouts[arity] = try m.loc.layoutOf(try m.placeOf(ft.result.toOptional()));
        const supply = try m.arena.alloc([]const Src, total);
        @memset(supply, &.{});
        const free = try m.arena.alloc(bool, total);
        @memset(free, true);
        const fnc = try m.arena.create(Contract.Fn);
        fnc.* = .{ .arity = arity, .layouts = layouts, .off = off, .supply = supply, .free = free };
        return fnc;
    }

    pub fn emptyContract(m: *Mod, params: []const PlaceId, result: PlaceId) Allocator.Error!*Contract.Contract {
        const arity: u32 = @intCast(params.len);
        const layouts = try m.arena.alloc(u32, arity + 1);
        const off = try m.arena.alloc(u32, arity + 1);
        var total: u32 = 0;
        for (params, 0..) |p, k| {
            layouts[k] = try m.loc.layoutOf(p);
            off[k] = total;
            total += @intCast(m.loc.layouts.items[layouts[k]].len);
        }
        off[arity] = total;
        layouts[arity] = try m.loc.layoutOf(result);
        const flags = try m.arena.alloc(u8, total);
        @memset(flags, 0);
        const res = try m.arena.alloc([]const Src, m.loc.layouts.items[layouts[arity]].len);
        @memset(res, &.{});
        const fns = try m.arena.alloc(?*const Contract.Fn, arity);
        @memset(fns, null);
        const c = try m.arena.create(Contract.Contract);
        c.* = .{ .arity = arity, .layouts = layouts, .off = off, .flags = flags, .res = res, .fns = fns };
        return c;
    }

    // ---- worded rows (ownership-v2.md §2.13.6) --------------------------------------

    fn has(words: u32, w: W) bool {
        return words & w.bit() != 0;
    }

    fn wordedContract(m: *Mod, di: u32) Allocator.Error!?*const Contract.Contract {
        const d = m.bir.decls[di];
        const sig = (try m.sigOf(di)) orelse return null;
        const arity: u32 = @intCast(sig.params.len);
        const c = try m.emptyContract(sig.params, sig.result);
        const flags = @constCast(c.flags);
        const fns = @constCast(c.fns);
        const rl = c.layouts[arity];
        const res_es = m.loc.layoutEntries(rl);
        const gpa = m.gpa;
        var res = try gpa.alloc(std.ArrayList(Src), res_es.len);
        defer {
            for (res) |*r| r.deinit(gpa);
            gpa.free(res);
        }
        for (res) |*r| r.* = .empty;
        var pw = try gpa.alloc(u32, arity);
        defer gpa.free(pw);
        @memset(pw, 0);
        var rw: u32 = 0;
        for (m.bir.ownSlotsV2(d)) |s| {
            if (s[0] == Bir.own_result) rw = s[1] else if (s[0] < arity) pw[s[0]] = s[1];
        }
        if (arity != 0 and has(pw[0], .entry)) {
            // An `entry` without the state protocol is no word: its record
            // goes to code that the checker does not see, and a function of
            // it that writes is refused where the record is made
            // (ownership-v2.md §2.13.4 item 4; the shape test is v2's).
            const names: Prepass.EntryNames = if (m.in.interner) |i| .{ .update = i.find("update"), .settle = i.find("settle") } else .{ .update = null, .settle = null };
            if (Prepass.entryProtocol(m.bir, d, 0, names)) c.entry = true else pw[0] = 0;
        }
        const rself = try m.selfLoc(sig.result);
        const relem = try m.loc.proj(sig.result, Step.elem);
        var described = false;
        for (0..arity) |j| {
            const w = pw[j];
            const pl = c.layouts[j];
            const pes = m.loc.layoutEntries(pl);
            const pself = try m.selfLoc(sig.params[j]);
            const is_fn = m.fnType(sig.vars[j].toOptional()) != null;
            if (is_fn) {
                for (flags[c.off[j]..c.off[j + 1]]) |*x| x.* |= Contract.flag_r;
                fns[j] = try m.wordedFn(sig, c, @intCast(j), w, res);
                if (has(w, .returned) or has(w, .stored) or has(w, .aliased)) described = true;
                if (has(w, .escaped) or has(w, .aliased)) for (flags[c.off[j]..c.off[j + 1]]) |*x| {
                    x.* |= Contract.flag_e;
                };
                continue;
            }
            // A parameter with no word is read by code that the checker does not see.
            const unknown = w == 0 or has(w, .unknown);
            // `shallow` (kernel §12): the operation reads the parameter's
            // storage and moves its values by reference, never reading what
            // they hold: no location below the storage is read.
            const shallow = !unknown and shallowParam(m.bir.ownSlotsV3(d), j);
            // What goes into a cell is behind it from then on: it escapes.
            const into_cell = has(w, .cellstored) or has(rw, .cellnew);
            for (pes, 0..) |pe, e| {
                const fl = &flags[c.off[j] + e];
                if (!has(w, .unused) and !(shallow and pe.loc != pself)) fl.* |= Contract.flag_r;
                if (has(w, .consumed) and !into_cell) fl.* |= Contract.flag_w;
                if (has(w, .written) and pe.loc == pself) fl.* |= Contract.flag_w;
                // A cell's handle is never `own`: a write of the cell asks nothing of the caller.
                if (has(w, .escaped) or into_cell or unknown) fl.* |= Contract.flag_e;
                const src: Src = .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) };
                // A word that puts the location in the result, where the
                // result has no location to hold it (an `Int`, a `Maybe Int`,
                // `⊤`, a phantom type): the answer is the same JavaScript
                // value, and a cast reads it back, so the cells escape here,
                // as a walked cast's do (`narrowed`, kernel §3.4). Placed
                // nowhere is never "gone" (research report 150).
                if (has(w, .aliased) or unknown) {
                    described = true;
                    c.nonlinear = true;
                    for (res) |*r| try r.append(gpa, src);
                    if (!try m.placedAnywhere(sig.result, res_es)) fl.* |= Contract.flag_e;
                    // At any place of the result: at a type variable of the
                    // result of another type than the location's, a cast
                    // (`aliased a → b`, JavaScript `[a]`; research report 151).
                    if (has(w, .aliased) and try m.aliasedCasts(sig.vars[j], pe.loc, sigResult(sig), res_es)) c.casts = true;
                }
                if (has(w, .returned)) {
                    described = true;
                    var found = false;
                    for (res_es, 0..) |re, ri| if (m.holdsAt(pe, re)) {
                        if (re.loc == pe.loc) found = true;
                        try res[ri].append(gpa, src);
                    };
                    if (!found) for (res) |*r| try r.append(gpa, src);
                    if (!try m.placedSafely(sig.result, res_es, pe)) fl.* |= Contract.flag_e;
                    if (try m.castsAt(sig.params[j], sig.result, sig.vars[j], sigResult(sig), pe)) c.casts = true;
                }
                if (has(w, .stored)) {
                    described = true;
                    const elem_typed = try m.typesOne(sig.vars[j], m.elemType(sigResult(sig)));
                    if (!try m.intoElems(res, sig.result, relem, pe, src, elem_typed)) fl.* |= Contract.flag_e;
                    if (relem) |pr| {
                        if (try m.castsAt(sig.params[j], pr.child, sig.vars[j], m.elemType(sigResult(sig)), pe)) c.casts = true;
                    } else if (pe.kind.wide()) c.casts = true;
                }
            }
        }
        // The result's own words. `fresh` says that each location of the
        // result holds new cells, and nothing more: a row builds no run, so no
        // rule derives that two locations hold two cells (`(n) => { const r =
        // {}; return {a: r, b: r}; }` is as true of `fresh { a : R, b : R }`
        // as two objects are). They are one site, `0`, so the cells of two
        // locations are one cell to the caller (kernel §4.2, §4.4; research
        // report 156). `exclusive` says that no new cell is at two places or
        // two paths: one site for each location, so a builder's storage and
        // its elements are two cells. A cell's handle (`cellnew`,
        // `cellempty`) is one new cell at each location of its own. A row that
        // makes one new list (`copyof` and its kin) has one site, `0`.
        if (has(rw, .fresh) or has(rw, .exclusive) or has(rw, .cellnew) or has(rw, .cellempty)) {
            described = true;
            const sites = has(rw, .exclusive) or has(rw, .cellnew) or has(rw, .cellempty);
            for (res, 0..) |*r, ri| try r.append(gpa, Src.fresh(if (sites) @intCast(ri) else 0, false));
        }
        // `copyof` of a record (`Record.copy`, kernel §11): a new object
        // whose fields hold parameter 0's values. The result's locations
        // are one row here, which cannot say which of them are the new
        // slots, so each holds a new cell and each of parameter 0's; a direct
        // call is applied precisely (`Frame.recordCopy`).
        if (has(rw, .copyof) and arity == 1 and m.isRecordPlace(sig.result)) {
            described = true;
            c.record_copy = true;
            c.nonlinear = true;
            for (res) |*r| {
                try r.append(gpa, Src.fresh(0, false));
                for (0..m.loc.layoutEntries(c.layouts[0]).len) |e| try r.append(gpa, .{ .kind = .param, .a = 0, .e = @intCast(e) });
            }
            // No location to hold the values: they escape (research report 150).
            for (m.loc.layoutEntries(c.layouts[0]), 0..) |pe, e| if (!try m.placedSafely(sig.result, res_es, pe)) {
                flags[c.off[0] + e] |= Contract.flag_e;
            };
        } else if (has(rw, .copyof) or has(rw, .concatenated) or has(rw, .prepended)) {
            described = true;
            for (res_es, 0..) |re, ri| if (re.loc == rself) try res[ri].append(gpa, Src.fresh(0, false));
            if (arity > 0 and !has(rw, .prepended)) try m.elemsToElems(res, sig, c, 0);
            if (arity > 1 and !has(rw, .copyof)) try m.elemsToElems(res, sig, c, 1);
            if (has(rw, .concatenated) and arity > 0) try m.selfToSelf(res, sig, c, 0);
            if (has(rw, .prepended) and arity > 1) try m.selfToSelf(res, sig, c, 1);
        }
        if (has(rw, .builderdone) and arity > 0) {
            described = true;
            // A location of the builder that no location of the result holds
            // (`holdsAt`) is at every one of them, as `returned`'s is: never
            // at none (research report 148). A result of no location holds
            // none of them, and they escape (research report 150).
            for (m.loc.layoutEntries(c.layouts[0]), 0..) |pe, e| {
                const src: Src = .{ .kind = .param, .a = 0, .e = @intCast(e) };
                var found = false;
                for (res_es, 0..) |re, ri| if (m.holdsAt(pe, re)) {
                    found = true;
                    try res[ri].append(gpa, src);
                };
                if (!found) for (res) |*r| try r.append(gpa, src);
                if (!try m.placedSafely(sig.result, res_es, pe)) flags[c.off[0] + e] |= Contract.flag_e;
                if (try m.castsAt(sig.params[0], sig.result, sig.vars[0], sigResult(sig), pe)) c.casts = true;
            }
        }
        if ((has(rw, .elementof) or has(rw, .taken)) and arity > 0) {
            described = true;
            if (has(rw, .taken)) c.taken = true;
            if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
                const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
                // A location of the element that the list's layout does not
                // place (`up` is `none`) is a source no word names: the
                // pessimistic row (research report 148).
                if (std.mem.indexOfScalar(u32, pr.up, none) != null) try m.undescribed(c, res, sig.result, true);
                for (child, 0..) |ce, k| {
                    if (pr.up[k] == none) continue;
                    const src: Src = .{ .kind = .param, .a = 0, .e = @intCast(pr.up[k]) };
                    var found = false;
                    for (res_es, 0..) |re, ri| if (m.holdsAt(ce, re)) {
                        if (re.loc == ce.loc) found = true;
                        try res[ri].append(gpa, src);
                    };
                    if (!found) for (res) |*r| try r.append(gpa, src);
                    // An element answered at a type of no location (`elementof
                    // Int`): it escapes (research report 150).
                    if (!try m.placedSafely(sig.result, res_es, ce)) flags[c.off[0] + pr.up[k]] |= Contract.flag_e;
                    if (try m.castsAt(pr.child, sig.result, m.elemType(sig.vars[0]), sigResult(sig), ce)) c.casts = true;
                }
            } else try m.undescribed(c, res, sig.result, true);
        }
        // A result that comes from behind a cell or from JavaScript, or
        // that no word describes: the pessimistic row (`undescribed`).
        const pessimistic = pessimisticRow(rw) or !described;
        if (pessimistic) try m.undescribed(c, res, sig.result, has(rw, .unknown));
        // `position` on parameter `q` (kernel §6 rule 10, *A position*): an
        // element that `elementof` answers is the one at the position `q`
        // names, and where parameter 0 is `written returned` beside a `stored`
        // value, the result's other elements are parameter 0's at the other
        // positions. Only where the words read parameter 0 as a list whole:
        // a row that casts, places a location anywhere or is pessimistic says
        // no position.
        if (!pessimistic and !c.casts and !c.nonlinear and arity > 0) if (positionParam(m.bir.ownSlotsV3(d), arity)) |q| {
            const at = has(rw, .elementof) and !has(rw, .taken);
            // With no `stored` value, the element at the position leaves the
            // result (`Dict.remove`, kernel §12): the other elements are
            // parameter 0's at the other positions all the same.
            const other = !at and has(pw[0], .written) and has(pw[0], .returned);
            if (at or other) if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
                for (res) |*r| for (r.items) |*s| if (s.kind == .param and s.a == 0 and std.mem.indexOfScalar(u32, pr.up, s.e) != null) {
                    s.p = Src.posOf(q, if (at) 0 else 1);
                };
            };
        };
        // A worded row builds no run (kernel §4.4): no part is tested against
        // another, so nothing derives that a cell is at one place of a summary
        // location of its result. Each such location that holds a cell is
        // `twice`, unless a word states the positions of what it puts there
        // (`statesPositions`): `(a) => [a, a]` is as true of `stored a →
        // fresh List a` as `(a) => [a]` is (research report 156).
        for (res, res_es, 0..) |*r, re, ri| {
            if (re.single) continue;
            const twice = for (r.items) |s| {
                if (pessimistic or !try m.statesPositions(sig, c, pw, rw, ri, s)) break true;
            } else false;
            if (twice) try r.append(gpa, Src.twice);
        }
        const out = @constCast(c.res);
        for (out, res) |*o, r| o.* = try Contract.normal(m.arena, r.items);
        if (std.debug.runtime_safety) try m.checkWordedPlaced(sig, c, pw, rw);
        if (std.debug.runtime_safety) try m.checkWordedCasts(sig, c, pw, rw);
        if (std.debug.runtime_safety) try m.checkWordedTwice(sig, c, pw, rw);
        return c;
    }

    /// Whether a word of a row states where source `s` is at the summary
    /// location `ri` of the result, so that a cell it names is at one of the
    /// location's places when the arguments are apart (kernel §4.4, §6 rule
    /// 10; research reports 156, 157). The one reading of these words: the
    /// marker (`wordedContract`) and the safe-build check
    /// (`checkWordedTwice`) both call it, so they cannot read the words two
    /// ways (#2559: they did, on `stored` beside a `written returned`
    /// record). The words that state positions, each by its definition
    /// (`language.md` §5.4, `ownership-v2.md` §2.13.6):
    ///
    /// - `returned`, `builderdone`, the list of `prepended` and the elements of
    ///   `copyof` and `concatenated` put a location at the result's location
    ///   of the same place: the result there is the parameter's own positions,
    ///   or a copy of them, or the two lists one after the other;
    /// - `stored` beside the one `written returned` parameter (`put`,
    ///   `push`, `set`, `insertAt`, `focus`), where that parameter and the
    ///   result are lists at their roots (`oneStore`), is one write of one
    ///   position of that list, and the first parameter of `prepended` is the
    ///   one item in front: each at the result's element location or below it;
    /// - `exclusive` says that each new cell of the result is at one place.
    ///
    /// Any other placement — a word that puts a location below another place
    /// (a wide one over the result's parts), `stored` into a new list or
    /// beside a `written returned` parameter that is no list at its root,
    /// `elementof`, `taken`, `aliased`, a parameter with no word, `fresh`
    /// without `exclusive`, `Record.copy`'s values, every placement of a row
    /// whose result comes from behind a cell or from JavaScript — states no count.
    fn statesPositions(m: *Mod, sig: Sig, c: *const Contract.Contract, pw: []const u32, rw: u32, ri: usize, s: Src) Allocator.Error!bool {
        if (c.record_copy or pessimisticRow(rw)) return false;
        const re = m.loc.layoutEntries(c.layouts[c.arity])[ri];
        switch (s.kind) {
            .outside, .twice => return true,
            .fresh => return has(rw, .exclusive),
            .answer => {
                const w = pw[s.a];
                const fnc = c.fns[s.a] orelse return false;
                if (has(w, .aliased)) return false;
                const ae = m.loc.layoutEntries(fnc.layouts[fnc.arity])[s.e];
                const at_place = has(w, .returned) and !has(w, .stored) and ae.loc == re.loc;
                const ft = m.fnType(sig.vars[s.a].toOptional()) orelse return false;
                const one_store = has(w, .stored) and !has(w, .returned) and try m.oneStore(sig, pw, s.a, ri, ft.result);
                return at_place or one_store;
            },
            .param => {
                const j = s.a;
                const w = pw[j];
                if (w == 0 or has(w, .unknown) or has(w, .aliased)) return false;
                if (j == 0 and (has(rw, .elementof) or has(rw, .taken))) return false;
                const pe = m.loc.layoutEntries(c.layouts[j])[s.e];
                const by_place = has(w, .returned) or
                    (j == 0 and (has(rw, .copyof) or has(rw, .concatenated) or has(rw, .builderdone))) or
                    (j == 1 and (has(rw, .concatenated) or has(rw, .prepended)));
                const by_store = has(w, .stored);
                if (by_place and by_store) return false;
                if (by_place) return pe.loc == re.loc;
                if (!by_store) return false;
                // `prepended`'s item: the validator makes the result a list.
                if (j == 0 and has(rw, .prepended)) return isElem(try m.loc.proj(sig.result, Step.elem), ri) and try m.typesOne(sig.vars[j], m.elemType(sigResult(sig)));
                return m.oneStore(sig, pw, j, ri, sig.vars[j]);
            },
        }
    }

    /// Whether the word `shallow` stands on parameter `j` (`Bir.ownSlotsV3`,
    /// kernel §12).
    fn shallowParam(slots: []const [2]u32, j: usize) bool {
        for (slots) |s| if (s[0] == j and s[1] & Ast.OwnWord3.shallow.bit() != 0) return true;
        return false;
    }

    /// The parameter that the word `position` stands on (`Bir.ownSlotsV3`,
    /// kernel §6 rule 10), or null: lowering keeps at most one, after the
    /// first parameter.
    fn positionParam(slots: []const [2]u32, arity: u32) ?usize {
        for (slots) |s| if (s[0] != 0 and s[0] < arity and s[1] & Ast.OwnWord3.position.bit() != 0) return s[0];
        return null;
    }

    /// A row whose result comes from behind a cell or from JavaScript: the
    /// pessimistic row (`undescribed`), and no placement of it states
    /// positions (kernel §4.4).
    fn pessimisticRow(rw: u32) bool {
        return has(rw, .lent) or has(rw, .lentoptional) or has(rw, .cellread) or has(rw, .unknown);
    }

    /// Whether `stored` on parameter `j`, a value of type `t`, is one write
    /// at one position of "that list" at result location `ri` (kernel §4.4):
    /// exactly one other parameter is `written returned`, it is a list at its
    /// root, the result is a list at its root, `t` is the element type of
    /// both, and `ri` is the result's element location or below it. A value
    /// of another type is not an element: the row puts it below one, inside
    /// a container no word names (`l.push([a, a])` for `stored List Int`
    /// into a `List (List (List Int))`), where the words say no count. A `written returned` record, tuple, `Maybe`, scalar or type
    /// variable writes no list a word names, two can write two lists, and a
    /// result with no `[*]` at its root holds the location at every place
    /// (`intoElems`): none of them states a position (research report 157).
    fn oneStore(m: *Mod, sig: Sig, pw: []const u32, j: usize, ri: usize, t: Var) Allocator.Error!bool {
        var dest: ?usize = null;
        for (pw, 0..) |w, k| if (k != j and has(w, .written) and has(w, .returned)) {
            if (dest != null) return false;
            dest = k;
        };
        const k = dest orelse return false;
        if (try m.loc.proj(sig.params[k], Step.elem) == null) return false;
        if (!isElem(try m.loc.proj(sig.result, Step.elem), ri)) return false;
        return try m.typesOne(t, m.elemType(sigResult(sig))) and try m.typesOne(t, m.elemType(sig.vars[k]));
    }

    /// Safe builds: a summary location of a worded row's result that is not
    /// `twice` holds only sources that a word puts there at stated positions
    /// (`statesPositions`, kernel §4.4, §6 rule 10), and a row without
    /// `exclusive` (or a cell's handle) names one site for all its new cells.
    /// It reads the contract the marker built, after `Contract.normal`, by the
    /// one reading of the words the marker uses: it checks the marking loop
    /// and the sites, not the reading. Two readings of the words, one here and
    /// one in the marker, disagreed on `stored` beside a `written returned`
    /// record and panicked on a row the validator accepts (research report
    /// 157, #2559). With the `twice` of a row turned off (research report
    /// 156's fault), core's first `fresh` row of a list of records
    /// (`Schema`'s issues) panics. Counts no work.
    fn checkWordedTwice(m: *Mod, sig: Sig, c: *const Contract.Contract, pw: []const u32, rw: u32) Allocator.Error!void {
        const units = m.loc.units;
        defer m.loc.units = units;
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        // A row that does not say `exclusive` (or make a cell's handle)
        // names one site for all its new cells: two locations can be one cell.
        const sites = has(rw, .exclusive) or has(rw, .cellnew) or has(rw, .cellempty);
        if (!sites) for (c.res) |srcs| for (srcs) |s| if (s.kind == .fresh and s.a != 0)
            std.debug.panic("own3: a row's new cells are at two sites with no word that says they are two cells (kernel §6 rule 10, §9)", .{});
        for (res_es, c.res, 0..) |re, srcs, ri| {
            if (re.single) continue;
            const marked = for (srcs) |s| {
                if (s.kind == .twice) break true;
            } else false;
            if (marked) continue;
            for (srcs) |s| if (!try m.statesPositions(sig, c, pw, rw, ri, s))
                std.debug.panic("own3: a summary location of a row's result holds a source that no word puts at stated positions, and is not twice (kernel §4.4, §6 rule 10, §9)", .{});
        }
    }

    /// Whether result location `ri` is the result's element location or below it.
    fn isElem(relem: ?*const Loc.Proj, ri: usize) bool {
        const pr = relem orelse return false;
        return std.mem.indexOfScalar(u32, pr.up, @intCast(ri)) != null;
    }

    /// Safe builds: a row whose word puts a parameter's wide location (a
    /// type variable, a `Js.Value`) at a place of the result of another type
    /// than the location's casts (`Contract.casts`): `returned` and
    /// `builderdone` at the same place of the result, `stored` at that place
    /// of its elements, `elementof` and `taken` an element of parameter 0 at
    /// that place of the result, `aliased` at any type variable of the
    /// result. The types are read again from the store, apart from the code
    /// that marked the row (`castsAt`, `aliasedCasts`): with the types not
    /// compared (research report 151's fault, the places alone), the first
    /// row of `returned a → b` panics. Kernel §6 rule 10, §9. Counts no work.
    fn checkWordedCasts(m: *Mod, sig: Sig, c: *const Contract.Contract, pw: []const u32, rw: u32) Allocator.Error!void {
        if (c.casts) return;
        const units = m.loc.units;
        defer m.loc.units = units;
        const rty = sigResult(sig);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        for (0..c.arity) |j| {
            const w = pw[j];
            if (m.fnType(sig.vars[j].toOptional()) != null) continue;
            for (m.loc.layoutEntries(c.layouts[j])) |pe| {
                if (!pe.kind.wide()) continue;
                const pt = try m.typeAt(sig.vars[j], pe.loc);
                var other = false;
                if (has(w, .returned) or (j == 0 and has(rw, .builderdone))) {
                    if (try m.loc.placeAt(sig.result, pe.loc) != null) other = other or !try m.typesOne(pt, try m.typeAt(rty, pe.loc));
                }
                if (has(w, .stored)) {
                    if (try m.loc.proj(sig.result, Step.elem)) |pr| {
                        if (try m.loc.placeAt(pr.child, pe.loc) != null) other = other or !try m.typesOne(pt, try m.typeAt(m.elemType(rty), pe.loc));
                    } else other = true;
                }
                if (has(w, .aliased)) for (res_es) |re| {
                    if (re.kind == .@"var") other = other or !try m.typesOne(pt, try m.typeAt(rty, re.loc));
                };
                if (other) std.debug.panic("own3: a row puts a wide location of parameter {d} at a place of the result of another type, and does not cast (kernel §6 rule 10, §9)", .{j});
            }
        }
        if ((has(rw, .elementof) or has(rw, .taken)) and c.arity > 0) {
            if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
                for (m.loc.layoutEntries(try m.loc.layoutOf(pr.child))) |ce| {
                    if (!ce.kind.wide()) continue;
                    if (try m.loc.placeAt(sig.result, ce.loc) == null) continue;
                    if (!try m.typesOne(try m.typeAt(m.elemType(sig.vars[0]), ce.loc), try m.typeAt(rty, ce.loc)))
                        std.debug.panic("own3: a row answers an element's wide location at a place of the result of another type, and does not cast (kernel §6 rule 10, §9)", .{});
                }
            }
        }
    }

    /// Whether two types read by `typeAt` are one: both known, and one type.
    fn typesOne(m: *Mod, a: ?Var, b: ?Var) Allocator.Error!bool {
        const x = a orelse return false;
        const y = b orelse return false;
        return m.sameType(x, y, 0);
    }

    /// Safe builds: each parameter location that a word puts in the result
    /// (`returned`, `stored`, `aliased`, `builderdone`, `elementof`, `taken`,
    /// the elements and storage of `copyof` and its kin, `Record.copy`'s
    /// values, and a function parameter's answer under `returned`, `stored`
    /// or `aliased`) is a source of some location of the result, or escapes.
    /// A row's placement never lands on no location without an escape
    /// (kernel §6 rule 10, §9; research report 150). It reads the words
    /// again, apart from the code that placed them, and counts no work.
    fn checkWordedPlaced(m: *Mod, sig: Sig, c: *const Contract.Contract, pw: []const u32, rw: u32) Allocator.Error!void {
        const gpa = m.gpa;
        const arity = c.arity;
        const total = c.off[arity];
        const held = try gpa.alloc(bool, total);
        defer gpa.free(held);
        @memset(held, false);
        var answered = try gpa.alloc(bool, arity);
        defer gpa.free(answered);
        @memset(answered, false);
        for (c.res) |srcs| for (srcs) |s| switch (s.kind) {
            .param => if (s.a < arity) {
                held[c.off[s.a] + s.e] = true;
            },
            .answer => if (s.a < arity) {
                answered[s.a] = true;
            },
            .fresh, .outside, .twice => {},
        };
        const want = struct {
            fn at(cc: *const Contract.Contract, hd: []const bool, j: usize, e: usize) void {
                const i = cc.off[j] + e;
                std.debug.assert(hd[i] or cc.flags[i] & Contract.flag_e != 0);
            }
        };
        for (0..arity) |j| {
            const w = pw[j];
            const n = c.off[j + 1] - c.off[j];
            if (c.fns[j]) |fnc| {
                const ans_n = m.loc.layoutEntries(fnc.layouts[fnc.arity]).len;
                if (ans_n != 0 and (has(w, .returned) or has(w, .stored) or has(w, .aliased)))
                    std.debug.assert(answered[j] or fnc.ans_escapes);
                continue;
            }
            if (has(w, .returned) or has(w, .stored) or has(w, .aliased)) for (0..n) |e| want.at(c, held, j, e);
            // `returned`: a wide location that does not escape is held by a
            // wide location of the result at or above its place, or at its
            // place where the result has no part of no location below it.
            if (has(w, .returned)) for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| {
                if (!pe.kind.wide() or c.flags[c.off[j] + e] & Contract.flag_e != 0) continue;
                var ok = false;
                for (m.loc.layoutEntries(c.layouts[arity]), c.res) |re, srcs| for (srcs) |s| {
                    if (s.kind != .param or s.a != j or s.e != e) continue;
                    if ((re.kind.wide() and m.loc.isPrefix(re.loc, pe.loc)) or (re.loc == pe.loc and !try m.loc.holeAt(sig.result, pe.loc))) ok = true;
                };
                std.debug.assert(ok);
            };
        }
        if (arity == 0) return;
        if (has(rw, .builderdone) or c.record_copy) for (0..c.off[1]) |e| want.at(c, held, 0, e);
        if (has(rw, .elementof) or has(rw, .taken)) if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
            for (pr.up) |u| if (u != none) want.at(c, held, 0, u);
        };
        if (!c.record_copy and (has(rw, .copyof) or has(rw, .concatenated) or has(rw, .prepended))) {
            for (0..@min(arity, 2)) |j| {
                if (j == 0 and has(rw, .prepended)) continue;
                if (j == 1 and has(rw, .copyof)) continue;
                const pself = try m.selfLoc(sig.params[j]);
                for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| if (pe.loc != pself or pe.kind.wide()) want.at(c, held, j, e);
            }
            for (0..@min(arity, 2)) |j| {
                if (!((j == 0 and has(rw, .concatenated)) or (j == 1 and has(rw, .prepended)))) continue;
                const pself = try m.selfLoc(sig.params[j]);
                for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| if (pe.loc == pself) want.at(c, held, j, e);
            }
        }
    }

    // ---- a worded body checked against its walk (kernel §6 rule 10) -----------------

    /// Per declaration of the module: whether its body reaches JavaScript
    /// that can see a cell (kernel §6 rule 10, *A worded body is checked
    /// against its walk*), so that its walk reads what it cannot follow. One
    /// of its edges (`Edges.declEdgesAt`: the values its instructions and
    /// local functions name, its dispatch terms) is
    ///
    /// - a declaration of core's `Js`, a `foreign` with no words, a markup
    ///   primitive or a name with no definition, named where the type it is
    ///   read at holds a cell (`touchesCells`: `Js.shiftRightZero` on two
    ///   `Int`s reads none);
    /// - another module's derived row with no published fact, or a codec:
    ///   the compiler's code, which no walk reads by a body (this module's
    ///   derived rows are read through the methods they call, which leg 3
    ///   yields as edges of their own);
    /// - a worded row that hands a parameter to code that no walk sees
    ///   (`handsUnseen`), or that casts;
    /// - a declaration with no words and no contract (its walk gave up, or
    ///   its module passed a limit), one whose contract casts, or one whose
    ///   own body reaches JavaScript, of this module or of another
    ///   (`Published.js`).
    ///
    /// A worded callee is read by its words, and its own body is checked
    /// where it is declared: it does not carry the bit. One pass over each
    /// declaration's edges, then a walk back along the edges into
    /// declarations with no words: linear in the edges.
    fn reachesJs(m: *Mod) Allocator.Error![]bool {
        const gpa = m.gpa;
        const bir = m.bir;
        const nd = bir.decls.len;
        const js = try m.arena.alloc(bool, nd);
        @memset(js, false);
        var rev = try gpa.alloc(std.ArrayList(u32), nd);
        defer {
            for (rev) |*r| r.deinit(gpa);
            gpa.free(rev);
        }
        for (rev) |*r| r.* = .empty;
        var edges: std.ArrayList(Edges.Edge) = .empty;
        defer edges.deinit(gpa);
        var at: std.ArrayList(u32) = .empty;
        defer at.deinit(gpa);
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(gpa);
        const dt: *const Dispatch = m.in.dispatch orelse &Dispatch.empty;
        const in_js = m.isJsModule(m.in.module);
        for (bir.decls, 0..) |d, di| {
            if (!d.kind.isValue() or d.body == .none) continue;
            edges.clearRetainingCapacity();
            at.clearRetainingCapacity();
            try Edges.declEdgesAt(&edges, &at, gpa, bir, dt, @intCast(di), null);
            const direct = for (edges.items, at.items) |e, pos| {
                const t: [2]u32 = switch (e) {
                    .top => |t| .{ m.in.module, t },
                    .ext => |x| blk: {
                        const mi = x.module.int();
                        if (mi >= m.in.provenance.len) break true;
                        const vd = m.in.provenance[mi].valueDecl(x.value) orelse break true;
                        break :blk .{ mi, vd.int() };
                    },
                    // This module's derived row: its body's methods are edges
                    // of their own (leg 3 walks through the rows).
                    .derived => continue,
                    // Another module's derived row, by its published fact.
                    .ext_derived => if ((try m.edgeEffect(e)).no_contract) break true else continue,
                    // A codec: the compiler's code, which no walk reads by a body.
                    .codec => break true,
                    // The compiler's own comparisons: they read their operands.
                    .primitive, .undetermined => continue,
                };
                const td = m.declOf(t) orelse break true;
                if (in_js or m.isJsModule(t[0])) {
                    if (try m.touchesCells(pos)) break true;
                    continue;
                }
                switch (calleeKind(m.in.birs[t[0]], td)) {
                    .js => if (try m.touchesCells(pos)) break true,
                    .worded => {
                        if (try m.handsUnseen(t)) break true;
                        if ((try m.declContract(t)).?.casts) break true;
                    },
                    .walked => {
                        const c = (try m.declContract(t)) orelse break true;
                        if (c.casts) break true;
                        if (t[0] == m.in.module) {
                            if (t[1] != di) try rev[t[1]].append(gpa, @intCast(di));
                        } else {
                            const p = (if (t[0] < m.shared.published.len) m.shared.published[t[0]] else null) orelse break true;
                            if (t[1] >= p.js.len or p.js[t[1]]) break true;
                        }
                    },
                }
            } else false;
            if (direct) {
                js[di] = true;
                try queue.append(gpa, @intCast(di));
            }
        }
        var next: usize = 0;
        while (next < queue.items.len) : (next += 1) {
            const t = queue.items[next];
            // A worded declaration does not carry the bit to its callers.
            if (bir.ownSlotsV2(bir.decls[t]).len != 0) continue;
            for (rev[t].items) |caller| if (!js[caller]) {
                js[caller] = true;
                try queue.append(gpa, caller);
            };
        }
        return js;
    }

    /// Whether the reference at instruction `pos` (`Edges.declEdgesAt`) is
    /// read at a type that holds a cell: a parameter, a function parameter
    /// or the result of the function type it is read at, or its own type.
    /// A position with no instruction of a reference (a row of the reference
    /// table, a dispatch site) is read as one that does.
    fn touchesCells(m: *Mod, pos: u32) Allocator.Error!bool {
        if (pos >= m.bir.insts.len) return true;
        const tag = m.tags[pos];
        if (tag != .top and tag != .ext_value) return true;
        const ty: Var.Optional = if (pos < m.in.inst_type.len) m.in.inst_type[pos] else .none;
        if (ty == .none) return true;
        if (m.fnType(ty)) |ft| {
            for (m.in.store.vars(ft.params)) |pv| {
                if (m.fnType(pv.toOptional()) != null) return true;
                if (m.loc.layoutEntries(try m.loc.layoutOf(try m.placeOf(pv.toOptional()))).len != 0) return true;
            }
            return m.loc.layoutEntries(try m.loc.layoutOf(try m.placeOf(ft.result.toOptional()))).len != 0;
        }
        return m.loc.layoutEntries(try m.loc.layoutOf(try m.placeOf(ty))).len != 0;
    }

    /// Whether the words of worded declaration `t` hand a location of a
    /// parameter to code that no walk sees (`reachesJs`): a parameter with
    /// no word, or `unknown`, that holds a cell, or a function parameter
    /// with no word, whose function JavaScript calls with every cell of
    /// every parameter; or the result word `unknown`. A row with no
    /// contract is unknown code.
    fn handsUnseen(m: *Mod, t: [2]u32) Allocator.Error!bool {
        const d = m.declOf(t) orelse return true;
        const c = (try m.declContract(t)) orelse return true;
        var pw = try m.gpa.alloc(u32, c.arity);
        defer m.gpa.free(pw);
        @memset(pw, 0);
        for (m.in.birs[t[0]].ownSlotsV2(d)) |s| {
            if (s[0] == Bir.own_result) {
                if (has(s[1], .unknown)) return true;
            } else if (s[0] < c.arity) pw[s[0]] = s[1];
        }
        for (pw, 0..) |w, j| {
            if (w != 0 and !has(w, .unknown)) continue;
            if (c.fns[j] != null or m.loc.layoutEntries(c.layouts[j]).len != 0) return true;
        }
        return false;
    }

    /// Whether module `mi` is core's `Js`.
    fn isJsModule(m: *const Mod, mi: u32) bool {
        if (!m.in.isCore(mi) or mi >= m.names.module_names.len) return false;
        return std.mem.eql(u8, m.names.module_names[mi], "Js");
    }

    const CalleeKind = enum { js, worded, walked };

    /// How a callee of module `bir` reaches its caller's walk
    /// (`reachesJs`): by its words, which are its contract; by its own
    /// walk; or by nothing a walk follows.
    fn calleeKind(bir: *const Bir, d: Bir.Decl) CalleeKind {
        if (bir.ownSlotsV2(d).len != 0) return .worded;
        return switch (d.kind) {
            .value => .walked,
            // A row of JavaScript with no words, a markup primitive, a name
            // with no definition, or no value at all: no fact a walk follows.
            .foreign_value, .vocab_markup, .annotation_only, .type, .type_alias, .foreign_type, .schema, .vocab_element, .vocab_attribute, .vocab_event => .js,
        };
    }

    /// The first fact of walk contract `c` of worded declaration `di` that
    /// its words' contract `wc` does not say, as the text of a refusal, or
    /// null when `c` is below `wc` (kernel §6 rule 10, *A worded body is
    /// checked against its walk*): what a caller reads of the walk, the
    /// words say too, or something more pessimistic. Both contracts are of
    /// this module's table and of one signature; a pair of other layouts (a
    /// function value declared with no parameter, whose walk is its
    /// lambda's) is not compared. Counts no work.
    fn falseWord(m: *Mod, di: u32, wc: *const Contract.Contract, c: *const Contract.Contract) Allocator.Error!?[]const u8 {
        const d = m.bir.decls[di];
        // `entry` is a protocol of the runtime (rule 13), and `Record.copy`'s
        // `copyof` is applied by its caller's own rule (`Frame.recordCopy`).
        if (wc.entry or wc.record_copy) return null;
        if (wc.arity != c.arity or !std.mem.eql(u32, wc.layouts, c.layouts)) return null;
        var pw = try m.gpa.alloc(u32, wc.arity);
        defer m.gpa.free(pw);
        @memset(pw, 0);
        var rw: u32 = 0;
        for (m.bir.ownSlotsV2(d)) |s| {
            if (s[0] == Bir.own_result) rw = s[1] else if (s[0] < wc.arity) pw[s[0]] = s[1];
        }
        const v3 = m.bir.ownSlotsV3(d);
        const name = m.names.declName(m.in.module, di);
        for (0..c.arity) |j| {
            const pes = m.loc.layoutEntries(c.layouts[j]);
            for (pes, 0..) |pe, e| {
                const cf = c.flags[c.off[j] + e];
                const wf = wc.flags[wc.off[j] + e];
                const missing = cf & ~wf;
                if (missing & (Contract.flag_r | Contract.flag_w | Contract.flag_e | Contract.flag_a) == 0) continue;
                const at = try m.atText(pe.loc);
                const words = try m.wordsText(pw[j], v3, j);
                if (cf & Contract.flag_r != 0 and wf & Contract.flag_r == 0)
                    return try m.falseText(name, "the body reads parameter {d}{s}, and its words `{s}` say that it does not ({s})", .{ j + 1, at, words, if (shallowParam(v3, j)) "`shallow`: no location below its storage" else "`unused`" });
                if (cf & Contract.flag_w != 0 and wf & Contract.flag_w == 0)
                    return try m.falseText(name, "the body writes parameter {d}{s}, and its words `{s}` say that it does not (`written` writes the storage, `consumed` all of it)", .{ j + 1, at, words });
                if (cf & Contract.flag_e != 0 and wf & Contract.flag_e == 0)
                    return try m.falseText(name, "the body lets parameter {d}{s} escape, and its words `{s}` keep it (`escaped` says that it escapes)", .{ j + 1, at, words });
                if (cf & Contract.flag_a != 0 and wf & (Contract.flag_a | Contract.flag_r) == 0)
                    return try m.falseText(name, "the body answers parameter {d}{s}, and its words `{s}` say that it does not read it", .{ j + 1, at, words });
            }
        }
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        const rwords = try m.wordsText(rw, &.{}, none);
        for (res_es, c.res, wc.res, 0..) |re, srcs, wsrcs, ri| {
            // One cell at two places of the location: a count. Where a cell
            // the body made is there, it can be the one at two places, and
            // the count is the walk's own: judged. Where only cells it was
            // handed are there, it is asserted by the words that state
            // positions, and not judged (`srcCovered`).
            if (hasKind(srcs, .twice) and !hasKind(wsrcs, .twice) and hasKind(srcs, .fresh))
                return try m.falseText(name, "the body answers one new cell at two places of the result{s}, and the words `{s}` say that each is at one", .{ try m.atText(re.loc), rwords });
            for (srcs) |s| {
                if (srcCovered(s, wsrcs)) {
                    // A new cell at two locations of the result: the words name one site for both.
                    if (s.kind == .fresh) if (try m.freshApart(c, wc, s, ri)) |other|
                        return try m.falseText(name, "the body answers one new value in the result{s} and in the result{s}, and the words `{s}` say that they are two (`exclusive`)", .{ try m.atText(re.loc), try m.atText(res_es[other].loc), rwords });
                    continue;
                }
                return try m.falseText(name, "the body answers {s} in the result{s}, and the words `{s}` do not say so", .{ try m.srcText(s), try m.atText(re.loc), rwords });
            }
        }
        if (c.nonlinear and !wc.nonlinear and !dupsOnly(c))
            return try m.falseText(name, "the body can answer one cell of a parameter at two places of its result, and its words say that it cannot", .{});
        if (c.casts and !wc.casts)
            return try m.falseText(name, "the body answers a value at a type variable of another type than its own (a cast), and its words say that it does not", .{});
        if (c.old_result and !wc.old_result)
            return try m.falseText(name, "the body can answer an object that was there before the call, and its words say that it answers a new one", .{});
        for (0..c.arity) |j| {
            const g = c.fns[j] orelse continue;
            const wg = wc.fns[j] orelse continue;
            if (g.arity != wg.arity or !std.mem.eql(u32, g.layouts, wg.layouts)) continue;
            const words = try m.wordsText(pw[j], v3, j);
            if (g.called and !wg.called) return try m.falseText(name, "the body calls function parameter {d}, and its words `{s}` say that it does not", .{ j + 1, words });
            if (g.lost and !wg.lost) return try m.falseText(name, "the body keeps function parameter {d} where no contract describes its holder, and its words `{s}` say that it does not (`once` and `many` say that it is called and not kept)", .{ j + 1, words });
            if (g.ans_escapes and !wg.ans_escapes) return try m.falseText(name, "the body lets the answer of function parameter {d} escape, and its words `{s}` say that it does not", .{ j + 1, words });
            if (g.rewrites and !wg.rewrites) return try m.falseText(name, "the body changes a value after it handed it to function parameter {d}, which its words `{s}` do not say", .{ j + 1, words });
            // `taken` asserts what the owner hands and reads no more, which no walk derives.
            const taken = has(pw[j], .taken);
            for (0..g.arity) |k| for (m.loc.layoutEntries(g.layouts[k]), 0..) |fe, i| {
                const slot = g.off[k] + i;
                const free = wg.free[slot] and !taken;
                if (free and !g.free[slot])
                    return try m.falseText(name, "the body reads again what it hands function parameter {d} at its parameter {d}{s}, and its words `{s}` say that it does not", .{ j + 1, k + 1, try m.atText(fe.loc), words });
                for (g.supply[slot]) |s| {
                    const covered = switch (s.kind) {
                        .param, .answer, .twice => srcCovered(s, wg.supply[slot]),
                        // A cell the body made: a caller names it only where the body answers it too.
                        .fresh => !answersSite(c, s.a) or hasKind(wg.supply[slot], .fresh),
                        // Outside every frame: a function the owner hands it to may not write it.
                        .outside => !wg.free[slot] or hasKind(wg.supply[slot], .outside),
                    };
                    if (!covered) return try m.falseText(name, "the body hands {s} to function parameter {d} at its parameter {d}{s}, and its words `{s}` do not say so", .{ try m.srcText(s), j + 1, k + 1, try m.atText(fe.loc), words });
                }
            };
        }
        return null;
    }

    /// Whether the words' sources `ws` at a location name the cells of the
    /// walk's source `s` there (`falseWord`): a parameter location at the
    /// same position or at none, a function parameter's answer; `outside`
    /// by `outside`; a cell the body made by `outside`, or,
    /// where it did not let it escape, by a new cell of the words, a
    /// parameter location or a function parameter's answer (each of which a
    /// caller writes only where it may write what it handed, and reads as
    /// held by what it handed).
    fn srcCovered(s: Src, ws: []const Src) bool {
        // A count of cells the body was handed is not judged: a word that
        // states positions asserts that each is at one place, as `taken`
        // asserts what a loop hands, and no walk of a permutation
        // (`List.swap`'s two `set`s) or of a merge derives it (research
        // report 162). A count where a cell the body made is is judged by
        // `falseWord`.
        if (s.kind == .twice) return true;
        for (ws) |w| switch (s.kind) {
            .param => if (w.kind == .param and w.a == s.a and w.e == s.e and (w.p == 0 or w.p == s.p)) return true,
            .answer => if (w.kind == .answer and w.a == s.a and w.e == s.e) return true,
            .twice => unreachable,
            .outside => if (w.kind == .outside) return true,
            .fresh => switch (w.kind) {
                .outside => return true,
                .fresh => if (s.e == 0 or w.e != 0) return true,
                .param, .answer => if (s.e == 0) return true,
                .twice => {},
            },
        };
        return false;
    }

    /// Whether walk contract `c` is `nonlinear` only by a cell at two places
    /// of one summary location (`twice`, which `srcCovered` reads): no
    /// parameter location or function answer is a source of two locations
    /// of its result, so no cell of a parameter is at two of them.
    fn dupsOnly(c: *const Contract.Contract) bool {
        for (c.res, 0..) |srcs, ri| for (srcs) |s| {
            if (s.kind != .param and s.kind != .answer) continue;
            for (c.res[ri + 1 ..]) |other| for (other) |x| if (x.kind == s.kind and x.a == s.a and x.e == s.e) return false;
        };
        return true;
    }

    fn hasKind(ws: []const Src, k: Src.Kind) bool {
        for (ws) |w| if (w.kind == k) return true;
        return false;
    }

    /// Whether walk contract `c` answers the cell the body made at site `a`.
    fn answersSite(c: *const Contract.Contract, a: u16) bool {
        for (c.res) |srcs| for (srcs) |s| if (s.kind == .fresh and s.a == a) return true;
        return false;
    }

    /// Another location of the walk's result where the new cell `s` at
    /// location `ri` is too, while the words name no one site for both: a
    /// cell at two places that the words say are two (`exclusive`).
    fn freshApart(m: *Mod, c: *const Contract.Contract, wc: *const Contract.Contract, s: Src, ri: usize) Allocator.Error!?usize {
        _ = m;
        for (c.res, 0..) |srcs, rj| {
            if (rj == ri) continue;
            const there = for (srcs) |x| {
                if (x.kind == .fresh and x.a == s.a) break true;
            } else false;
            if (!there) continue;
            if (hasKind(wc.res[ri], .outside) or hasKind(wc.res[rj], .outside)) continue;
            const shared = for (wc.res[ri]) |x| {
                if (x.kind != .fresh) continue;
                if (for (wc.res[rj]) |y| {
                    if (y.kind == .fresh and y.a == x.a) break true;
                } else false) break true;
            } else false;
            if (!shared) return rj;
        }
        return null;
    }

    fn srcText(m: *Mod, s: Src) Allocator.Error![]const u8 {
        return switch (s.kind) {
            .param => std.fmt.allocPrint(m.arena, "parameter {d}'s value{s}", .{ s.a + 1, if (s.p == 0) "" else if ((s.p - 1) % 2 == 0) " at the position its key names" else " at the other positions" }),
            .answer => std.fmt.allocPrint(m.arena, "the answer of function parameter {d}", .{s.a + 1}),
            .twice => "one cell at two places of a list (`twice`)",
            .outside => "a value outside every frame (a top-level value, or JavaScript's)",
            .fresh => if (s.e != 0) "a new value that it let escape" else "a new value",
        };
    }

    /// The words of parameter `j` (or of the result, `j == none`), as written.
    fn wordsText(m: *Mod, w: u32, v3: []const [2]u32, j: usize) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(m.arena);
        for (std.enums.values(W)) |x| if (has(w, x)) {
            if (out.written().len != 0) out.writer.writeAll(" ") catch return error.OutOfMemory;
            out.writer.writeAll(@tagName(x)) catch return error.OutOfMemory;
        };
        if (j != none) for (v3) |s| if (s[0] == j) for (std.enums.values(Ast.OwnWord3)) |x| if (s[1] & x.bit() != 0) {
            if (out.written().len != 0) out.writer.writeAll(" ") catch return error.OutOfMemory;
            out.writer.writeAll(@tagName(x)) catch return error.OutOfMemory;
        };
        if (out.written().len == 0) return "(none)";
        return out.written();
    }

    /// ` at ` and location text `l`, or nothing for a value's own storage.
    fn atText(m: *Mod, loc: u32) Allocator.Error![]const u8 {
        const l = try m.locText(loc);
        if (l.len == 0) return "";
        return std.fmt.allocPrint(m.arena, " at {s}", .{l});
    }

    fn falseText(m: *Mod, name: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        const what = try std.fmt.allocPrint(m.arena, fmt, args);
        return std.fmt.allocPrint(m.arena, "{s} is refused: false-word: {s}", .{ name, what });
    }

    /// The result of a worded row that the words do not describe: it can be
    /// a cell outside every frame (JavaScript's, a cell's contents), so no
    /// frame may write it, and it can hold every cell of every parameter, at
    /// any place (kernel §6.10: a missing fact is the pessimistic one).
    ///
    /// A result of no location holds no parameter location as a source.
    /// Where a word says that the result can be anything (`unknown`), or puts
    /// a parameter's elements in it that the result's layout cannot place
    /// (`elementof`, `taken`; `escape`), the JavaScript value can still be
    /// each, and a cast reads it back: every parameter location escapes
    /// (research report 150). Where the result has no word and each parameter
    /// has a word that does not put it in the result (`borrowed List a →
    /// Int`, `List.length`), those words are the positive facts: no word
    /// places a parameter there, and a result of a type of no location is
    /// no cell of a frame. A result from behind a cell (`lent`, `cellread`)
    /// is the cell's contents, which escaped where they went in.
    fn undescribed(m: *Mod, c: *Contract.Contract, res: []std.ArrayList(Src), result: PlaceId, escape: bool) Allocator.Error!void {
        c.nonlinear = true;
        for (res) |*r| {
            try r.append(m.gpa, Src.outside);
            for (0..c.arity) |j| for (0..m.loc.layoutEntries(c.layouts[j]).len) |e| try r.append(m.gpa, .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) });
        }
        if (escape and !try m.placedAnywhere(result, m.loc.layoutEntries(c.layouts[c.arity]))) for (@constCast(c.flags)) |*x| {
            x.* |= Contract.flag_e;
        };
    }

    /// Put `src`, a source at the location `from` of a parameter, among the
    /// result's elements. Whether each of its cells is where a reader can
    /// name it (`placedSafely` at the element's place, `placedAnywhere`
    /// where the result has no element): where not (a result of no location,
    /// one with no element, an element of no location), the caller makes it
    /// escape (research report 150). A value that is no element (`elem_typed`
    /// false: `stored List Int` beside a list of `List (List Int)`) is put
    /// below an element, at a depth no word names: it is at every element
    /// location, never at the one its label path names (research report 157).
    fn intoElems(m: *Mod, res: []std.ArrayList(Src), result: PlaceId, relem: ?*const Loc.Proj, from: Loc.Entry, src: Src, elem_typed: bool) Allocator.Error!bool {
        const pr = relem orelse {
            for (res) |*r| try r.append(m.gpa, src);
            return m.placedAnywhere(result, m.loc.layoutEntries(try m.loc.layoutOf(result)));
        };
        const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
        var found = false;
        var placed = false;
        if (elem_typed) for (child, 0..) |ce, k| if (m.holdsAt(from, ce) and pr.up[k] != none) {
            if (ce.loc == from.loc) found = true;
            placed = true;
            try res[pr.up[k]].append(m.gpa, src);
        };
        if (!found) for (pr.up) |u| if (u != none) {
            placed = true;
            try res[u].append(m.gpa, src);
        };
        return placed and try m.placedSafely(pr.child, child, from);
    }

    /// The result's elements hold the elements of parameter `j`. An element
    /// location that no location of the result holds but the storage (a
    /// `copyof Int`) escapes (research report 150).
    fn elemsToElems(m: *Mod, res: []std.ArrayList(Src), sig: Sig, c: *const Contract.Contract, j: u32) Allocator.Error!void {
        const pself = try m.selfLoc(sig.params[j]);
        const rself = try m.selfLoc(sig.result);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| {
            // The list's own storage is the new list's, not an element; a
            // wide entry there (a parameter of a type variable) holds the
            // elements too, so it is read as one (research report 148).
            if (pe.loc == pself and !pe.kind.wide()) continue;
            const src: Src = .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) };
            var found = false;
            var placed = false;
            for (res_es, 0..) |re, ri| if (m.holdsAt(pe, re) and re.loc != rself) {
                if (re.loc == pe.loc) found = true;
                placed = true;
                try res[ri].append(m.gpa, src);
            };
            if (!found) for (res_es, 0..) |re, ri| if (re.loc != rself) {
                placed = true;
                try res[ri].append(m.gpa, src);
            };
            // A wide element location (`copyof` of a list of a type variable)
            // whose cells can be at a part of the result of no location escapes
            // too (`placedSafely`).
            if (!placed or (pe.kind.wide() and !try m.placedSafely(sig.result, res_es, pe))) @constCast(c.flags)[c.off[j] + e] |= Contract.flag_e;
            if (try m.castsAt(sig.params[j], sig.result, sig.vars[j], sigResult(sig), pe)) @constCast(c).casts = true;
        }
    }

    /// The result's storage can be parameter `j`'s. A result with no storage
    /// to hold it lets it escape (research report 150).
    fn selfToSelf(m: *Mod, res: []std.ArrayList(Src), sig: Sig, c: *const Contract.Contract, j: u32) Allocator.Error!void {
        const pself = try m.selfLoc(sig.params[j]);
        const rself = try m.selfLoc(sig.result);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        for (m.loc.layoutEntries(c.layouts[j]), 0..) |pe, e| if (pe.loc == pself) {
            var placed = false;
            for (res_es, 0..) |re, ri| if (re.loc == rself) {
                placed = true;
                try res[ri].append(m.gpa, .{ .kind = .param, .a = @intCast(j), .e = @intCast(e) });
            };
            if (!placed) @constCast(c.flags)[c.off[j] + e] |= Contract.flag_e;
        };
    }

    /// The words of a function parameter: `taken` hands it the elements of
    /// parameter 0, `stored` puts its answer among the result's elements,
    /// `returned` makes its answer the result.
    fn wordedFn(m: *Mod, sig: Sig, c: *const Contract.Contract, j: u32, w: u32, res: []std.ArrayList(Src)) Allocator.Error!?*const Contract.Fn {
        const ft = m.fnType(sig.vars[j].toOptional()) orelse return null;
        const pvars = m.in.store.vars(ft.params);
        const arity: u32 = @intCast(pvars.len);
        const layouts = try m.arena.alloc(u32, arity + 1);
        const off = try m.arena.alloc(u32, arity + 1);
        var total: u32 = 0;
        for (pvars, 0..) |pv, k| {
            layouts[k] = try m.loc.layoutOf(try m.placeOf(pv.toOptional()));
            off[k] = total;
            total += @intCast(m.loc.layouts.items[layouts[k]].len);
        }
        off[arity] = total;
        const rplace = try m.placeOf(ft.result.toOptional());
        layouts[arity] = try m.loc.layoutOf(rplace);
        const supply = try m.arena.alloc([]const Src, total);
        const free = try m.arena.alloc(bool, total);
        const taken = has(w, .taken);
        @memset(free, taken);
        // What the words do not say the row hands the function, the
        // pessimistic row does: every cell of every parameter, not `free`
        // (kernel §6.10). `taken` names the elements below.
        var every: std.ArrayList(Src) = .empty;
        defer every.deinit(m.gpa);
        for (0..c.arity) |pj| for (0..m.loc.layoutEntries(c.layouts[pj]).len) |pe| try every.append(m.gpa, .{ .kind = .param, .a = @intCast(pj), .e = @intCast(pe) });
        @memset(supply, try Contract.normal(m.arena, every.items));
        if (taken and arity > 0 and sig.params.len > 0) {
            // The function is handed one element of parameter 0, taken out of the list.
            if (try m.loc.proj(sig.params[0], Step.elem)) |pr| {
                const child = m.loc.layoutEntries(try m.loc.layoutOf(pr.child));
                for (m.loc.layoutEntries(layouts[0]), 0..) |fe, e| {
                    var srcs: std.ArrayList(Src) = .empty;
                    defer srcs.deinit(m.gpa);
                    for (child, 0..) |ce, k| if (ce.loc == fe.loc and pr.up[k] != none) try srcs.append(m.gpa, .{ .kind = .param, .a = 0, .e = @intCast(pr.up[k]) });
                    if (srcs.items.len != 0) supply[off[0] + e] = try Contract.normal(m.arena, srcs.items);
                    for (srcs.items) |s| @constCast(c.flags)[c.off[0] + s.e] |= Contract.flag_s;
                }
            }
        }
        // What the row hands the function at a location of another type
        // than the parameter location it comes from (a cast: `feed :
        // borrowed a, once returned (b → c) → c`, JavaScript `f([a])`) is
        // below the function parameter's place, where the caller's function
        // reads its own type and can cast it back: it escapes (research
        // report 151's review).
        for (0..arity) |k| for (m.loc.layoutEntries(layouts[k]), 0..) |fe, e| {
            const ft_k = try m.typeAt(pvars[k], fe.loc);
            for (supply[off[k] + e]) |s| {
                if (s.kind != .param or s.a >= c.arity) continue;
                const pe = m.loc.layoutEntries(c.layouts[s.a])[s.e];
                // A location of no type variable (a list handed where the words
                // do not say what is handed) is the pessimistic supply, no cast.
                if ((pe.kind != .@"var" and pe.kind != .@"opaque") or !fe.kind.wide()) continue;
                if (!try m.typesOne(try m.typeAt(sig.vars[s.a], pe.loc), ft_k)) @constCast(c.flags)[c.off[s.a] + s.e] |= Contract.flag_e;
            }
        };
        // Its answer.
        const ans = m.loc.layoutEntries(layouts[arity]);
        const res_es = m.loc.layoutEntries(c.layouts[c.arity]);
        const relem = try m.loc.proj(sig.result, Step.elem);
        // An answer location that a word puts in the result where no location
        // of the result holds it (`once returned (⊤ → a) → Int`) is placed
        // nowhere: it escapes, as an answer that no word places does
        // (research report 150).
        var unplaced = false;
        for (ans, 0..) |ae, e| {
            const src: Src = .{ .kind = .answer, .a = @intCast(j), .e = @intCast(e) };
            if (has(w, .returned)) {
                var found = false;
                for (res_es, 0..) |re, ri| if (m.holdsAt(ae, re)) {
                    if (re.loc == ae.loc) found = true;
                    try res[ri].append(m.gpa, src);
                };
                if (!found) for (res) |*r| try r.append(m.gpa, src);
                if (!try m.placedSafely(sig.result, res_es, ae)) unplaced = true;
                // A cast answer is below the result, where no reader names it:
                // every cell it holds escapes (research report 151's review).
                if (try m.castsAt(rplace, sig.result, ft.result, sigResult(sig), ae)) {
                    @constCast(c).casts = true;
                    unplaced = true;
                }
            }
            if (has(w, .stored)) {
                const elem_typed = try m.typesOne(ft.result, m.elemType(sigResult(sig)));
                if (!try m.intoElems(res, sig.result, relem, ae, src, elem_typed)) unplaced = true;
                if (relem) |pr| {
                    if (try m.castsAt(rplace, pr.child, ft.result, m.elemType(sigResult(sig)), ae)) {
                        @constCast(c).casts = true;
                        unplaced = true;
                    }
                } else if (ae.kind.wide()) {
                    @constCast(c).casts = true;
                    unplaced = true;
                }
            }
            if (has(w, .aliased)) {
                for (res) |*r| try r.append(m.gpa, src);
                if (!try m.placedAnywhere(sig.result, res_es)) unplaced = true;
                if (try m.aliasedCasts(ft.result, ae.loc, sigResult(sig), res_es)) {
                    @constCast(c).casts = true;
                    unplaced = true;
                }
            }
        }
        const fnc = try m.arena.create(Contract.Fn);
        fnc.* = .{
            .arity = arity,
            .layouts = layouts,
            .off = off,
            .supply = supply,
            .free = free,
            .called = true,
            // A cell's callback runs once, now; the cell keeps what it answers.
            .lost = !(taken or has(w, .once) or has(w, .many) or has(w, .cellupdate) or has(w, .cellmodify)),
            // An answer that holds a cell and that no word puts in the
            // result goes where no word says: it escapes (kernel §6.10; research
            // report 148). No row of `core/` or a platform has one.
            .ans_escapes = unplaced or has(w, .cellupdate) or has(w, .cellmodify) or (ans.len != 0 and !has(w, .returned) and !has(w, .stored) and !has(w, .aliased)),
        };
        return fnc;
    }

    // ---- one declaration --------------------------------------------------------------

    /// Walk declaration `di` to its contract, or null: it has no body, no
    /// signature, or its walk gave up (kernel §3.3; then its lines are all
    /// refused, and `limits` says so).
    fn walkDecl(m: *Mod, di: u32) Allocator.Error!?*const Contract.Contract {
        const d = m.bir.decls[di];
        const body = d.body.unwrap() orelse return null;
        // A declaration of the module passed its budget, or a type the
        // layout limit: the module authorises no write, so no other is
        // walked (kernel §8). Each publishes nothing, and an importer reads
        // it as unknown code.
        if (m.stopped()) {
            m.failed_decl[di] = true;
            m.incomplete[di] = true;
            return null;
        }
        // One budget for the declaration, whatever the number of its walks
        // (kernel §8): the rounds of its group count against it together.
        m.beginDecl(di);
        @memset(m.lframe[d.locals_start..d.locals_end], 0);
        @memset(m.lv[d.locals_start..d.locals_end], Frame.v_unbound);
        @memset(m.lbinder[d.locals_start..d.locals_end], 0);
        var f = try Frame.init(m, null, di, false, none);
        const params = m.bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Inst.Index);
        const sig = try m.sigOf(di);
        f.own_params = @intCast(params.len);
        for (params, 0..) |p, k| {
            const place = if (sig) |s| (if (k < s.params.len) s.params[k] else m.var_place) else m.var_place;
            const ty: Var.Optional = if (sig) |s| (if (k < s.vars.len) s.vars[k].toOptional() else .none) else .none;
            try f.addParam(place, p.int(), ty);
        }
        const result_place = if (sig) |s| (if (params.len == s.params.len) s.result else try m.placeOfInst(body.int())) else try m.placeOfInst(body.int());
        try f.walkBody(body.int());
        // Past the budget no walk goes on (kernel §8): `finish` is not run,
        // and the declaration gives up below.
        const c = if (m.steps_over) undefined else try f.finish(result_place);
        m.endDecl(di);
        if (m.steps_over) {
            // A walk past its steps (kernel §8): the declaration gives up, loudly.
            m.module_over = true;
            try m.declLimit(di, try m.budgetLine(di, ""));
            m.failed_decl[di] = true;
            m.incomplete[di] = true;
            return null;
        }
        if (f.failed) {
            try m.declLimit(di, try std.fmt.allocPrint(m.arena, "limit {s}: the walk gave up", .{m.names.declName(m.in.module, di)}));
            m.failed_decl[di] = true;
            m.incomplete[di] = true;
            return null;
        }
        if (params.len == 0) {
            // A function value declared with no parameter: a call of it runs the lambda its body is.
            if (m.tags[body.int()] == .lambda) return m.code_contract[body.int()];
            // A constant: its contract says which locations it holds a cell at.
            return c;
        }
        return c;
    }

    /// Walk the `via` conversions of schema declaration `di` (kernel
    /// §6.14). The compiled workers of the schema (`S.print`, `S.parse`,
    /// …) and its `S.schema` value hold each conversion for as long as the
    /// program runs, and call its functions with values that the program
    /// may still hold. No walk of the program follows those calls, so each
    /// conversion is a value in the default location: each function in it
    /// goes to the `top` use, where one that writes its parameter is
    /// refused, and each cell it holds escapes. The declaration has no
    /// contract; a walk that gives up or passes its steps is a limit line.
    fn walkSchema(m: *Mod, di: u32) Allocator.Error!void {
        const d = m.bir.decls[di];
        var any = false;
        for (d.inst_start.int()..d.inst_end.int()) |i| if (m.tags[i] == .schema_via) {
            any = true;
        };
        if (!any) return;
        if (m.stopped()) {
            m.incomplete[di] = true;
            return;
        }
        @memset(m.lframe[d.locals_start..d.locals_end], 0);
        @memset(m.lv[d.locals_start..d.locals_end], Frame.v_unbound);
        @memset(m.lbinder[d.locals_start..d.locals_end], 0);
        var f = try Frame.init(m, null, di, false, none);
        m.beginDecl(di);
        for (d.inst_start.int()..d.inst_end.int()) |i| if (m.tags[i] == .schema_via) {
            if (m.steps_over) break;
            try f.walkHeld(m.datas[i].lhs);
        };
        if (!m.steps_over) _ = try f.finish(m.var_place);
        m.endDecl(di);
        if (m.steps_over or f.failed) m.incomplete[di] = true;
        if (m.steps_over) m.module_over = true;
        if (m.steps_over) {
            try m.declLimit(di, try m.budgetLine(di, ""));
        } else if (f.failed) {
            try m.declLimit(di, try std.fmt.allocPrint(m.arena, "limit {s}: the walk gave up", .{m.names.declName(m.in.module, di)}));
        }
    }

    /// A `--library` build: host JavaScript can call each function that the
    /// module exports, at any time, with values that it still holds (kernel
    /// §6.14; `Reach.collectRoots` roots the same names). Each is a function
    /// in the default location (rule 8): one that writes its parameter is
    /// refused. A constant that holds a function put it there where it was
    /// made, and its walk sent it to the `top` use already.
    fn walkExports(m: *Mod) Allocator.Error!void {
        var dis: std.ArrayList(u32) = .empty;
        defer dis.deinit(m.gpa);
        for (m.bir.interface) |index| try dis.append(m.gpa, index.int());
        // The entry declaration is exported too.
        for (m.bir.decls, 0..) |d, i| {
            if (d.kind == .value and d.body != .none and m.bir.symbol(d.name) == InternPool.WellKnown.main.symbol()) try dis.append(m.gpa, @intCast(i));
        }
        for (dis.items) |di| {
            const d = m.bir.decls[di];
            if (d.kind != .value) continue;
            const body = d.body.unwrap() orelse continue;
            if (!try m.isFunction(.{ m.in.module, di })) continue;
            if (m.stopped()) return;
            var f = try Frame.init(m, null, di, false, none);
            m.beginDecl(di);
            try f.walkExported(.{ m.in.module, di }, body.int());
            if (!m.steps_over) _ = try f.finish(m.var_place);
            m.endDecl(di);
            if (m.steps_over) {
                m.module_over = true;
                try m.declLimit(di, try m.budgetLine(di, " of the export"));
            } else if (f.failed) try m.declLimit(di, try std.fmt.allocPrint(m.arena, "limit {s}: the walk of the export gave up", .{m.names.declName(m.in.module, di)}));
            _ = m.walk_arena.reset(.retain_capacity);
        }
    }

    fn nameLess(m: *const Mod, a: u32, b: u32) bool {
        return std.mem.order(u8, m.names.declName(m.in.module, a), m.names.declName(m.in.module, b)) == .lt;
    }

    /// The order in which each round of a recursive group walks its
    /// members (kernel §6 rule 9): callees first. A depth-first walk of the
    /// group's own calls, started at each member in the order of their
    /// names, puts each member after the members it calls, the calls of a
    /// body in the order they are written. It reads the names and the
    /// bodies alone, never where a declaration stands in the module, so
    /// the rounds, and whether the group settles within its limit, are the
    /// same in any order of the declarations. Research report 141: a ring
    /// of 40 functions walked in the module's order settled in a few rounds
    /// with the callees written first, and did not settle in 64 with the
    /// callers first, since a contract then moved one member each round.
    fn groupOrder(m: *Mod, members: []u32) Allocator.Error!void {
        std.mem.sort(u32, members, @as(*const Mod, m), nameLess);
        const n = members.len;
        // `group_pos`, a column by declaration: each member's position, and
        // `none` again for each when the order is made.
        const pos = m.group_pos;
        for (members, 0..) |di, k| pos[di] = @intCast(k);
        defer for (members) |di| {
            pos[di] = none;
        };
        // Each member's callees in the group, by position in `members`, in
        // the order the body writes them, each once.
        var edges: std.ArrayList(u32) = .empty;
        defer edges.deinit(m.gpa);
        const starts = try m.gpa.alloc(u32, n + 1);
        defer m.gpa.free(starts);
        const seen = try m.gpa.alloc(u32, n);
        defer m.gpa.free(seen);
        @memset(seen, none);
        for (members, 0..) |di, k| {
            starts[k] = @intCast(edges.items.len);
            const d = m.bir.decls[di];
            for (d.inst_start.int()..d.inst_end.int()) |i| {
                const target: ?[2]u32 = switch (m.tags[i]) {
                    .top => .{ m.in.module, m.datas[i].lhs },
                    .method_call => m.methodTarget(@intCast(i)),
                    // No other instruction names a declaration of this module.
                    .local, .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_value, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => null,
                };
                const t = target orelse continue;
                if (t[0] != m.in.module) continue;
                if (t[1] >= pos.len or pos[t[1]] == none) continue;
                const to = pos[t[1]];
                if (seen[to] == k) continue;
                seen[to] = @intCast(k);
                try edges.append(m.gpa, to);
            }
        }
        starts[n] = @intCast(edges.items.len);
        // Postorder, with an explicit stack of (member, next edge).
        const order = try m.gpa.alloc(u32, n);
        defer m.gpa.free(order);
        var done: u32 = 0;
        const visited = try m.gpa.alloc(bool, n);
        defer m.gpa.free(visited);
        @memset(visited, false);
        var stack: std.ArrayList([2]u32) = .empty;
        defer stack.deinit(m.gpa);
        for (0..n) |root| {
            if (visited[root]) continue;
            visited[root] = true;
            try stack.append(m.gpa, .{ @intCast(root), starts[root] });
            while (stack.items.len != 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top[1] < starts[top[0] + 1]) {
                    const to = edges.items[top[1]];
                    top[1] += 1;
                    if (!visited[to]) {
                        visited[to] = true;
                        try stack.append(m.gpa, .{ to, starts[to] });
                    }
                    continue;
                }
                order[done] = members[top[0]];
                done += 1;
                _ = stack.pop();
            }
        }
        std.debug.assert(done == n);
        @memcpy(members, order);
    }

    fn solveGroup(m: *Mod, members: []const u32, recursive: bool) Allocator.Error!void {
        for (members) |di| {
            m.state[di] = .working;
            m.contracts[di] = if (recursive) try m.bottom(di) else null;
            m.contractChanged(di);
            if (m.contracts[di]) |c| try m.drafts.put(m.gpa, @intFromPtr(c), {});
        }
        defer m.drafts.clearRetainingCapacity();
        const mark = m.lines.items.len;
        const lmark = m.limits.items.len;
        var rounds: u32 = 0;
        while (true) : (rounds += 1) {
            var changed = false;
            var over = false;
            m.lines.shrinkRetainingCapacity(mark);
            m.limits.shrinkRetainingCapacity(lmark);
            for (members) |di| m.failed_decl[di] = false;
            for (members) |di| {
                const got = try m.walkDecl(di);
                if (m.steps_over) over = true;
                _ = m.walk_arena.reset(.retain_capacity);
                const old = m.contracts[di];
                // A walk that gave up has no contract, whatever the rounds
                // before found: a callee with no contract is unknown code.
                const next: ?*const Contract.Contract = if (got) |g| (if (old) |o| try Contract.join(m.arena, o, g) else g) else null;
                if ((old == null) != (next == null) or (old != null and !Contract.eql(old.?, next.?))) changed = true;
                m.contracts[di] = next;
                m.contractChanged(di);
                if (recursive) if (next) |c| try m.drafts.put(m.gpa, @intFromPtr(c), {});
            }
            if (!recursive or !changed) break;
            if (over) {
                // A member passed its steps in this round (kernel §8): its
                // walk gave up and its limit line is made. The rounds stop;
                // a contract of a round before the fixed point says less
                // than the group does, so no member publishes one.
                for (members) |di| {
                    m.contracts[di] = null;
                    m.failed_decl[di] = true;
                    m.contractChanged(di);
                }
                break;
            }
            if (rounds > 64) {
                // The line names the member first by name: the walk's
                // order is the call graph's, and neither depends on the
                // order of the declarations.
                var first = members[0];
                for (members[1..]) |di| if (m.nameLess(di, first)) {
                    first = di;
                };
                const text = if (members.len == 1) try std.fmt.allocPrint(m.arena, "limit {s}: the group did not settle", .{m.names.declName(m.in.module, first)}) else try std.fmt.allocPrint(m.arena, "limit {s}: the group of {d} declarations did not settle", .{ m.names.declName(m.in.module, first), members.len });
                try m.declLimit(first, text);
                // A contract of a round that is not the last says less than the
                // group does: no member publishes one (kernel §8). An importer
                // reads each as unknown code; a limit line of a module that is
                // not the app's is no error, so the importer would read it.
                for (members) |di| {
                    m.contracts[di] = null;
                    m.failed_decl[di] = true;
                    m.contractChanged(di);
                }
                break;
            }
        }
        for (members) |di| m.state[di] = .done;
    }

    // ---- text -----------------------------------------------------------------------------

    fn refName(m: *const Mod, t: [2]u32) Allocator.Error![]const u8 {
        if (t[0] >= m.names.module_names.len) return "?";
        return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ m.names.module_names[t[0]], m.names.declName(t[0], t[1]) });
    }

    fn localName(m: *const Mod, d: Bir.Decl, local: u32) []const u8 {
        const name = m.bir.locals[d.locals_start + local].name;
        return if (name == .none) "_" else m.symbolText(name);
    }

    fn opName(m: *Mod, f: *const Frame, inst: u32) Allocator.Error![]const u8 {
        if (inst == none) return "call";
        switch (m.tags[inst]) {
            .top, .ext_value => if (m.calleeOf(inst)) |t| return m.refName(t),
            .method_call => return if (m.methodTarget(inst)) |t| m.refName(t) else "<derived method>",
            .type_dispatch => return "<dispatched method>",
            .local => return m.localName(f.d, m.datas[inst].lhs),
            // No other instruction has a name the text can give.
            .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => {},
        }
        return "call";
    }

    fn baseText(m: *Mod, f: *const Frame, inst: u32) Allocator.Error![]const u8 {
        if (inst == none) return "<value>";
        const data = m.datas[inst];
        switch (m.tags[inst]) {
            .local => return m.localName(f.d, data.lhs),
            .list => return "<literal>",
            .lambda => return "<lambda>",
            .record, .record_update => return "<record>",
            .tuple => return "<tuple>",
            .top, .ext_value => if (m.calleeOf(inst)) |t| return m.refName(t),
            .field_access => return std.fmt.allocPrint(m.arena, "{s}.{s}", .{ try m.baseText(f, data.lhs), m.symbolText(@fromBackingInt(data.rhs)) }),
            .tuple_index => return std.fmt.allocPrint(m.arena, "{s}.{d}", .{ try m.baseText(f, data.lhs), data.rhs }),
            .call => {
                if (m.spreadOf(f.d, inst) != null) return "<construction>";
                if (m.isListAppend(inst)) return "<++>";
                switch (m.tags[data.lhs]) {
                    .ctor, .ext_ctor => return "<constructor …>",
                    .top, .ext_value => if (m.calleeOf(data.lhs)) |t| return std.fmt.allocPrint(m.arena, "<call {s}>", .{try m.refName(t)}),
                    // Any other callee has no name the text can give.
                    .local, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .tuple, .list, .record, .record_update, .field_access, .tuple_index, .call, .method_call, .type_dispatch, .lambda, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => {},
                }
                return "<call>";
            },
            .method_call => if (m.methodTarget(inst)) |t| return std.fmt.allocPrint(m.arena, "<call {s}>", .{try m.refName(t)}),
            // No other instruction has a name the text can give.
            .ctor, .import_value, .import_ctor, .qualified, .qualified_ctor, .schema_type_ref, .schema_value_ref, .schema_ctor_ref, .ext_ctor, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .type_var, .type_top, .type_import, .type_qualified, .ext_type, .schema_type_top, .ext_schema_type, .type_app, .type_fn, .type_unit, .type_tuple, .type_record, .type_record_ext, .schema_ref, .schema_app, .schema_paren, .schema_record, .schema_field, .schema_value, .schema_tagged, .schema_variant, .schema_as, .schema_via, .schema_optional, .schema_nullable, .schema_expr_ref, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target, .int, .float, .char, .string, .chunk, .interp, .unit, .type_dispatch, .let, .let_def, .let_pattern, .let_stmt, .case, .branch, .@"try", .markup, .pat_wild, .pat_var, .pat_ctor, .pat_int, .pat_char, .pat_string, .pat_unit, .pat_tuple, .pat_list, .pat_spread, .pat_record, .pat_as, .@"error" => {},
        }
        return "<expression>";
    }

    pub fn locText(m: *Mod, loc: u32) Allocator.Error![]const u8 {
        if (loc == 0) return "";
        var labels: std.ArrayList(u64) = .empty;
        defer labels.deinit(m.gpa);
        try m.loc.labels(loc, &labels, m.gpa);
        var out: std.Io.Writer.Allocating = .init(m.arena);
        for (labels.items) |lw| {
            const l: Loc.Label = @bitCast(lw);
            switch (l.kind) {
                .field => out.writer.print(".{s}", .{m.names.field(m.names.ctx, l.payload)}) catch return error.OutOfMemory,
                .index => out.writer.print(".{d}", .{l.payload}) catch return error.OutOfMemory,
                .ctor_arg => out.writer.print("#{s}.{d}", .{ m.names.ctor(m.names.ctx, l.head, l.payload >> 12), l.payload & 0xfff }) catch return error.OutOfMemory,
                .elem => out.writer.writeAll("[*]") catch return error.OutOfMemory,
                .contents => out.writer.writeAll("◆") catch return error.OutOfMemory,
                .row => out.writer.writeAll(".…") catch return error.OutOfMemory,
                .member => out.writer.print("⟨{s}⟩", .{m.names.type_name(m.names.ctx, l.head)}) catch return error.OutOfMemory,
                .env => out.writer.writeAll("◇") catch return error.OutOfMemory,
                .slot => out.writer.print("⟨{d}⟩", .{l.payload}) catch return error.OutOfMemory,
                .fslot => out.writer.print(".{s}=", .{m.names.field(m.names.ctx, l.payload)}) catch return error.OutOfMemory,
            }
        }
        return out.written();
    }

    pub fn useText(m: *Mod, f: *const Frame, point: u32) Allocator.Error![]const u8 {
        const pos = m.names.position(m.names.ctx, m.in.module, m.tokens[point]);
        return std.fmt.allocPrint(m.arena, "it is read again at {d}:{d} ({s})", .{ pos.line, pos.col, try m.baseText(f, point) });
    }

    pub fn addLine(m: *Mod, f: *const Frame, d: anytype, ground: Facts.Verdict.Accepted) Allocator.Error!void {
        const op: []const u8 = switch (d.op) {
            .construction => "construction",
            .append => "++",
            .update => "update",
            .call, .supply => if (d.kind == .send) "send" else if (d.kind == .callsite) try std.fmt.allocPrint(m.arena, "call {s}", .{try m.opName(f, d.callee_inst)}) else try m.opName(f, d.callee_inst),
        };
        const base = try std.fmt.allocPrint(m.arena, "{s}{s}", .{ try m.baseText(f, d.base_inst), try m.locText(d.loc) });
        const cause: Facts.Cause = d.refused orelse .unknown;
        try m.lines.append(m.gpa, .{
            .inst = d.point,
            .token = d.token,
            .kind = d.kind,
            .op = op,
            .base = base,
            .refused = d.refused != null,
            .accepted = ground,
            .cause = cause,
            .detail = if (d.detail.len != 0) d.detail else causeDetail(cause),
            .record = d.record or d.kind == .update,
            .hoists = if (@hasField(@TypeOf(d), "hoists")) try m.arena.dupe(OwnHoists.Read, d.hoists) else &.{},
        });
    }

    fn causeDetail(c: Facts.Cause) []const u8 {
        return switch (c) {
            .unknown => "the checker has no claim on this value",
            .captured => "a function captured it",
            .call => "it is the answer of a function parameter",
            .element => "one cell can be at two positions of it",
            .disjoint => "another operand of the same operation reaches it",
            .held_operand => "an operand that waits for its consumer holds it",
            .escaped => "it escaped before the write",
            // These carry the detail of their own line (`d.detail`).
            .top_level, .captured_edit, .later_use, .alias, .supply, .need, .limit, .exclusive, .once, .payload, .read_only, .level, .comparison, .loan => "",
        };
    }

    pub fn addRefusal(m: *Mod, f: *const Frame, inst: u32, cause: Facts.Cause, detail: []const u8) Allocator.Error!void {
        return m.addRefusalOf(f, inst, cause, detail, false);
    }

    /// `addRefusal` of a function handed as evidence (kernel §6 rule 11).
    pub fn addEvidenceRefusal(m: *Mod, f: *const Frame, inst: u32, detail: []const u8) Allocator.Error!void {
        return m.addRefusalOf(f, inst, .call, detail, true);
    }

    fn addRefusalOf(m: *Mod, f: *const Frame, inst: u32, cause: Facts.Cause, detail: []const u8, evidence: bool) Allocator.Error!void {
        // One line for each refusal: a walk can meet one refusal on each of
        // many paths (kernel §8), and each would be a diagnostic.
        const key: RefusalKey = .{ .inst = inst, .cause = @backingInt(cause), .detail = std.hash.Wyhash.hash(0, detail) };
        const got = try m.refusals.getOrPut(m.gpa, key);
        if (got.found_existing) {
            const i = got.value_ptr.*;
            if (i < m.lines.items.len) {
                const l = m.lines.items[i];
                if (l.inst == inst and l.refused and l.kind == .callsite and std.mem.eql(u8, l.op, "value") and l.cause == cause and std.mem.eql(u8, l.detail, detail)) return;
            }
        }
        got.value_ptr.* = @intCast(m.lines.items.len);
        try m.lines.append(m.gpa, .{ .inst = inst, .token = m.tokens[inst], .kind = .callsite, .op = "value", .base = try m.baseText(f, inst), .refused = true, .cause = cause, .detail = detail, .evidence = evidence });
    }

    pub fn addEntryLine(m: *Mod, f: *const Frame, inst: u32, code: anytype, model: bool, loc: u32, ok: bool) Allocator.Error!void {
        _ = f;
        const name: []const u8 = if (code.decl[0] != none) try m.refName(code.decl) else "<lambda>";
        try m.lines.append(m.gpa, .{
            .inst = inst,
            .token = m.tokens[inst],
            .kind = .entry,
            .op = try std.fmt.allocPrint(m.arena, "entry {s}", .{name}),
            .base = try std.fmt.allocPrint(m.arena, "{s}{s}", .{ if (model) "model" else "msg", try m.locText(loc) }),
            .refused = !ok,
            .accepted = .entry,
            .cause = .unknown,
            .detail = if (ok) "" else "the runtime does not hand this as the function's own",
        });
    }

    fn summaryText(m: *Mod, di: u32, c: *const Contract.Contract) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(m.arena);
        const w = &out.writer;
        w.print("summary {s}:", .{m.names.declName(m.in.module, di)}) catch return error.OutOfMemory;
        for (0..c.arity) |j| {
            for (m.loc.layoutEntries(c.layouts[j]), 0..) |e, k| {
                const fl = c.flags[c.off[j] + k];
                if (fl == 0) continue;
                w.print(" π{d}{s} {s}{s}", .{ j + 1, try m.locText(e.loc), if (fl & Contract.flag_w != 0) "W" else "", if (fl & Contract.flag_e != 0) "E" else "" }) catch return error.OutOfMemory;
            }
            if (c.fns[j]) |fnc| {
                w.print(" π{d} fn{s}{s}{s}{s}", .{ j + 1, if (fnc.called) " called" else "", if (fnc.lost) " lost" else "", if (fnc.ans_escapes) " answer-escapes" else "", if (fnc.rewrites) " rewrites" else "" }) catch return error.OutOfMemory;
                for (0..fnc.arity) |k| for (m.loc.layoutEntries(fnc.layouts[k]), 0..) |e, i| {
                    const slot = fnc.off[k] + i;
                    w.print(" ({d}{s}{s}", .{ k + 1, try m.locText(e.loc), if (fnc.free[slot]) "" else " held" }) catch return error.OutOfMemory;
                    try m.srcsText(w, fnc.supply[slot]);
                    w.writeAll(")") catch return error.OutOfMemory;
                };
            }
        }
        w.writeAll("; res") catch return error.OutOfMemory;
        for (m.loc.layoutEntries(c.layouts[c.arity]), 0..) |e, k| {
            w.print(" [{s}", .{try m.locText(e.loc)}) catch return error.OutOfMemory;
            try m.srcsText(w, c.res[k]);
            w.writeAll("]") catch return error.OutOfMemory;
        }
        return out.written();
    }

    fn srcsText(m: *Mod, w: *std.Io.Writer, srcs: []const Src) Allocator.Error!void {
        _ = m;
        for (srcs) |s| switch (s.kind) {
            .fresh => w.print(" fresh{d}{s}", .{ s.a, if (s.e != 0) "!" else "" }) catch return error.OutOfMemory,
            .outside => w.writeAll(" outside") catch return error.OutOfMemory,
            .param => {
                w.print(" π{d}@{d}", .{ s.a + 1, s.e }) catch return error.OutOfMemory;
                // At the position parameter `q` names (`[πq]`), or at the others (`[≠πq]`).
                if (s.p != 0) w.print("[{s}π{d}]", .{ if ((s.p - 1) % 2 == 0) "" else "≠", (s.p - 1) / 2 + 1 }) catch return error.OutOfMemory;
            },
            .answer => w.print(" answer{d}@{d}", .{ s.a + 1, s.e }) catch return error.OutOfMemory,
            .twice => w.writeAll(" twice") catch return error.OutOfMemory,
        };
    }
};

/// Whether an instruction names or runs code: a reference to a value or a
/// function, a function the program makes, a call of any kind, markup (whose
/// runtime calls what it is given). A call into the program's code starts at
/// one of these, or at a name the compiler makes up (kernel §6.14, the list).
/// No `else`: a new kind of instruction compiles only once it is named here.
fn namesCode(t: Inst.Tag) bool {
    return switch (t) {
        .local,
        .top,
        .ext_value,
        .import_value,
        .qualified,
        .schema_value_ref,
        .schema_expr_ref,
        .schema_member_top,
        .ext_schema_member,
        .call,
        .method_call,
        .type_dispatch,
        .lambda,
        .markup,
        => true,
        // A constructor runs no code of the program; a literal, a
        // construction, a projection, a binding, a type, a pattern or a
        // schema plan names none of its own (its operands are instructions
        // of their own). A tagged schema's constructor is a constructor:
        // the backend emits `{$: tag, a: payload}` or the bare tag, as for
        // a type's (`js/SchemaCtor.zig`, `Lower.ctorValue`); in a pattern
        // it is a tag test. No worker runs (kernel §6.14).
        .ctor,
        .ext_ctor,
        .schema_ctor_top,
        .ext_schema_ctor,
        .import_ctor,
        .qualified_ctor,
        .schema_ctor_ref,
        .schema_type_ref,
        .type_var,
        .type_top,
        .type_import,
        .type_qualified,
        .ext_type,
        .schema_type_top,
        .ext_schema_type,
        .type_app,
        .type_fn,
        .type_unit,
        .type_tuple,
        .type_record,
        .type_record_ext,
        .schema_ref,
        .schema_app,
        .schema_paren,
        .schema_record,
        .schema_field,
        .schema_value,
        .schema_tagged,
        .schema_variant,
        .schema_as,
        .schema_via,
        .schema_optional,
        .schema_nullable,
        .schema_parameter,
        .schema_primitive,
        .schema_target_top,
        .ext_schema_target,
        .int,
        .float,
        .char,
        .string,
        .chunk,
        .interp,
        .unit,
        .tuple,
        .list,
        .record,
        .record_update,
        .field_access,
        .tuple_index,
        .let,
        .let_def,
        .let_pattern,
        .let_stmt,
        .case,
        .branch,
        .@"try",
        .pat_wild,
        .pat_var,
        .pat_ctor,
        .pat_int,
        .pat_char,
        .pat_string,
        .pat_unit,
        .pat_tuple,
        .pat_list,
        .pat_spread,
        .pat_record,
        .pat_as,
        .@"error",
        => false,
    };
}

/// The mechanical check of kernel §6.14 (safe builds): every instruction
/// that names or runs code (`namesCode`), in every declaration whose code
/// the backend emits, was evaluated by a walk or accounted for by a rule
/// (`Frame.noteWalked`). The kinds of declaration are a `switch` with no
/// `else`: a new kind compiles only once it says whether it has code and
/// which walk covers it. So a part of the program that the backend emits
/// and no walk reads — a schema's `via` before research report 129 — fails
/// here on the first program that has one, not in a blind test.
fn checkCovered(m: *Mod) void {
    if (!std.debug.runtime_safety) return;
    // A module past the layout limit publishes nothing and authorises no write.
    if (m.loc.over.items.len != 0) return;
    for (m.bir.decls, 0..) |d, di| {
        const has_code = switch (d.kind) {
            // Its body (`walkDecl`; a worded one is walked for its lines).
            .value => d.body != .none,
            // Its `via` conversions (`walkSchema`); the rest is a plan the
            // compiler turns into workers, which call only the `via`s
            // (rule 14) and the workers of other schemas.
            .schema => true,
            // The body is a sibling's JavaScript (rule 10) or the markup
            // runtime's (rule 12); none is a walk's.
            .foreign_value, .vocab_markup => false,
            // No code.
            .annotation_only, .type, .type_alias, .foreign_type, .vocab_element, .vocab_attribute, .vocab_event => false,
        };
        if (!has_code or m.incomplete[di]) continue;
        for (d.inst_start.int()..d.inst_end.int()) |i| {
            if (!namesCode(m.tags[i]) or m.walked.isSet(i)) continue;
            std.debug.panic("ownership v3: instruction {d} ({t}) of {s} names code that no walk evaluated: a call into the program's code with no rule (kernel §6.14)", .{ i, m.tags[i], m.names.declName(m.in.module, @intCast(di)) });
        }
    }
}

/// Check module `in`. The result lives in `arena`, the published contracts in `gpa`.
pub fn checkModule(gpa: Allocator, arena: Allocator, in: *const Groups.Input, shared: *const Shared, names: Names, options: Options) Allocator.Error!Result {
    const bir = in.bir;
    var m: Mod = .{
        .gpa = gpa,
        .arena = arena,
        .walk_arena = .init(gpa),
        .in = in,
        .bir = bir,
        .tags = bir.insts.items(.tag),
        .datas = bir.insts.items(.data),
        .tokens = bir.insts.items(.main_token),
        .names = names,
        .shared = shared,
        .markup_type = options.markup_type,
        .kept_lets = options.kept_lets,
    };
    defer m.walk_arena.deinit();
    defer m.uniq_seen.deinit(gpa);
    defer m.share.deinit(gpa);
    defer m.places.deinit(gpa);
    defer m.account.deinit(gpa);
    m.account.walk = .growth;
    m.adapter = .{ .in = in, .gpa = gpa, .places = &m.places, .account = &m.account, .repeat_reservations = false };
    defer m.adapter.deinit();
    m.loc = try Loc.Table.init(gpa, arena, &m.places);
    defer m.loc.deinit();
    defer m.lines.deinit(gpa);
    defer m.refusals.deinit(gpa);
    defer m.spread_root.deinit(gpa);
    m.var_place = m.adapter.placeOfVar(.none) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("ownership v3: the place of a type variable"),
    };
    m.loc.plain_var = m.var_place.int();
    var prepass_arena: std.heap.ArenaAllocator = .init(gpa);
    defer prepass_arena.deinit();
    m.prepass = try Prepass.run(gpa, prepass_arena.allocator(), .{ .bir = bir, .dispatch = in.dispatch });

    const nd = bir.decls.len;
    // The module's budget: what its instructions earn (kernel §8).
    m.module_size = bir.insts.len;
    m.module_budget = moduleBudget(try m.earnedUnits());
    defer gpa.free(m.inst_earn);
    m.lv = try gpa.alloc(Frame.Val, bir.locals.len);
    defer gpa.free(m.lv);
    m.lframe = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lframe);
    @memset(m.lframe, 0);
    m.lbinder = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lbinder);
    @memset(m.lbinder, 0);
    m.lcode = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lcode);
    @memset(m.lcode, Loc.none);
    m.lgroup = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lgroup);
    @memset(m.lgroup, Loc.none);
    m.lindex = try gpa.alloc(u32, bir.locals.len);
    defer gpa.free(m.lindex);
    @memset(m.lindex, Loc.none);
    defer m.groups.deinit(gpa);
    m.let_seen = try std.DynamicBitSetUnmanaged.initEmpty(gpa, bir.insts.len);
    defer m.let_seen.deinit(gpa);
    m.recalled = try gpa.alloc(bool, bir.insts.len);
    defer gpa.free(m.recalled);
    @memset(m.recalled, false);
    m.code_caps = try gpa.alloc([]const u32, bir.insts.len);
    defer gpa.free(m.code_caps);
    @memset(m.code_caps, &.{});
    m.code_contract = try gpa.alloc(?*const Contract.Contract, bir.insts.len);
    defer gpa.free(m.code_contract);
    @memset(m.code_contract, null);
    m.contracts = try gpa.alloc(?*const Contract.Contract, nd);
    defer gpa.free(m.contracts);
    @memset(m.contracts, null);
    const nrows = if (in.dispatch) |dt| dt.derived.len else 0;
    m.row_info = try gpa.alloc(RowInfo, nrows);
    defer gpa.free(m.row_info);
    m.row_gen = try gpa.alloc(u32, nrows);
    defer gpa.free(m.row_gen);
    @memset(m.row_gen, 0);
    m.row_slot = try gpa.alloc(u32, nrows);
    defer gpa.free(m.row_slot);
    m.row_slot_gen = try gpa.alloc(u32, nrows);
    defer gpa.free(m.row_slot_gen);
    @memset(m.row_slot_gen, 0);
    m.row_read = try std.DynamicBitSetUnmanaged.initEmpty(gpa, nd);
    defer m.row_read.deinit(gpa);
    m.failed_decl = try gpa.alloc(bool, nd);
    defer gpa.free(m.failed_decl);
    @memset(m.failed_decl, false);
    m.decl_steps = try gpa.alloc(u64, nd);
    defer gpa.free(m.decl_steps);
    @memset(m.decl_steps, 0);
    m.decl_budget = try gpa.alloc(u64, nd);
    defer gpa.free(m.decl_budget);
    @memset(m.decl_budget, 0);
    m.incomplete = try gpa.alloc(bool, nd);
    defer gpa.free(m.incomplete);
    @memset(m.incomplete, false);
    if (std.debug.runtime_safety) m.walked = try std.DynamicBitSetUnmanaged.initEmpty(gpa, bir.insts.len);
    defer if (std.debug.runtime_safety) m.walked.deinit(gpa);
    m.group_pos = try gpa.alloc(u32, nd);
    defer gpa.free(m.group_pos);
    @memset(m.group_pos, none);
    m.state = try gpa.alloc(State, nd);
    defer gpa.free(m.state);
    @memset(m.state, .todo);
    m.worded_done = try gpa.alloc(bool, nd);
    defer gpa.free(m.worded_done);
    @memset(m.worded_done, false);
    m.readers = try gpa.alloc(?Contract.Reader, in.birs.len);
    defer gpa.free(m.readers);
    defer m.drafts.deinit(gpa);
    defer m.sites.deinit(gpa);
    @memset(m.readers, null);
    m.spread_root = try std.DynamicBitSetUnmanaged.initEmpty(gpa, bir.insts.len);
    for (bir.decls) |d| for (bir.spreads(d)) |s| if (s.root < bir.insts.len) m.spread_root.set(s.root);

    // Each declaration that a walk can read, its budget, before any walk
    // (kernel §8): the module's budget is the sum, whatever the order.
    // Past the layout limit no declaration is walked, and none needs one.
    // The module's budget is not tested here: whether it stopped the loop
    // would depend on the order of the declarations. The declarations go
    // by name, so the one that first meets a type past the layout limit,
    // which the limit line names, does not depend on their order either.
    {
        var by_name: std.ArrayList(u32) = .empty;
        defer by_name.deinit(gpa);
        for (bir.decls, 0..) |d, di| {
            if (!((d.kind == .value and d.body != .none) or d.kind == .schema)) continue;
            try by_name.append(gpa, @intCast(di));
        }
        std.mem.sort(u32, by_name.items, @as(*const Mod, &m), Mod.nameLess);
        for (by_name.items) |di| {
            // Past the cap the module passes its budget, whatever the
            // declarations after this one earn (`declBudget`).
            if (m.loc.units > module_cap) break;
            m.decl_budget[di] = try m.declBudget(di);
            if (m.loc.over.items.len != 0) {
                m.over_decl = di;
                break;
            }
        }
    }
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(gpa);
    for (0..m.prepass.starts.len - 1) |gi| {
        members.clearRetainingCapacity();
        for (m.prepass.order[m.prepass.starts[gi]..m.prepass.starts[gi + 1]]) |di| {
            const d = bir.decls[di];
            if (d.kind != .value or d.body == .none or bir.ownSlotsV2(d).len != 0) continue;
            try members.append(gpa, di);
        }
        if (members.items.len == 0) continue;
        if (m.prepass.recursive[gi] and members.items.len > 1) try m.groupOrder(members.items);
        try m.solveGroup(members.items, m.prepass.recursive[gi]);
    }
    // A worded declaration's contract is its words. Its body is walked for
    // its own verdicts when every contract of the module is known; what the
    // walk found is kept, to be checked against the words at the end.
    const walked = try arena.alloc(?*const Contract.Contract, bir.decls.len);
    @memset(walked, null);
    for (bir.decls, 0..) |d, di| {
        if (!d.kind.isValue() or bir.ownSlotsV2(d).len == 0) continue;
        _ = try m.declContract(.{ in.module, @intCast(di) });
        if (d.kind != .value or d.body == .none) continue;
        walked[di] = try m.walkDecl(@intCast(di));
        // Its contract is its words, a trusted row, whatever its walk found.
        m.failed_decl[di] = false;
        _ = m.walk_arena.reset(.retain_capacity);
    }
    // A schema declaration's `via` conversions (kernel §6.14), when every
    // contract of the module is known.
    for (bir.decls, 0..) |d, di| {
        if (d.kind != .schema) continue;
        try m.walkSchema(@intCast(di));
        _ = m.walk_arena.reset(.retain_capacity);
    }
    if (options.library) try m.walkExports();
    checkCovered(&m);
    // A walk that gave up publishes nothing (kernel §3.3).
    if (std.debug.runtime_safety) for (m.contracts, m.failed_decl) |c, failed| std.debug.assert(!(failed and c != null));
    // A type past the layout limit (kernel §8, `Loc.max_layout_entries`): the
    // walk read its places as one summary location, so the module authorises
    // no write (`limits`) and publishes no contract. An importer reads each
    // of its declarations as unknown code.
    if (m.loc.over.items.len != 0) {
        try m.limits.append(m.arena, try m.overLimit());
        @memset(m.contracts, null);
    }
    // A module past a limit publishes no contract, and so no derived fact.
    // Past its budget the rows are not read either (kernel §8): an importer
    // reads a row with no fact as code that writes and keeps.
    var derived: []const Contract.DerivedFact = if (m.stopped()) &.{} else try m.derivedFacts();
    // The rows' reads count too: a module past its budget only here
    // authorises no write either, loudly, and publishes no row's fact.
    if (!m.stopped() and m.overBudget()) {
        m.module_over = true;
        derived = &.{};
        try m.limits.append(m.arena, .{ .text = try moduleLimitText(m.arena, m.names.module_names[in.module], m.module_budget, m.module_size), .token = null });
    }
    // A module past its budget publishes no contract of a walk, not even of
    // the declarations walked before the one that passed it (kernel §8):
    // what an importer reads of it must not depend on the order of its
    // declarations (research report 135's review). A worded declaration's
    // contract is its words, which no walk made, and stays.
    if (m.module_over) for (bir.decls, m.contracts) |d, *c| {
        if (!d.kind.isValue() or bir.ownSlotsV2(d).len == 0) c.* = null;
    };
    // Which bodies reach JavaScript, and each worded body that reaches none
    // checked against its walk (kernel §6 rule 10, *A worded body is checked
    // against its walk*). Last, when every budget has been read: they count
    // no work, so no limit and no verdict depends on them.
    {
        const units = m.loc.units;
        defer m.loc.units = units;
        if (options.rows) m.js = try m.reachesJs();
        for (bir.decls, walked, 0..) |d, w, di| {
            if (d.kind != .value or d.body == .none or bir.ownSlotsV2(d).len == 0) continue;
            if (di >= m.js.len or m.js[di]) continue;
            // Words that no importer reads (the module publishes no
            // contract) are not trusted, and need no check.
            const wc = m.contracts[di] orelse continue;
            // A walk that gave up or passed a limit found nothing to check
            // the words against, and its words are trusted all the same:
            // they are refused.
            const text = if (w) |c| try m.falseWord(@intCast(di), wc, c) else try m.falseText(m.names.declName(in.module, @intCast(di)), "its body reaches no JavaScript, and its walk gave up or passed a limit, so no word of it can be checked", .{});
            if (text) |t| try m.false_words.append(m.arena, .{ .text = t, .token = d.name_token });
        }
    }
    // The contracts as text, for a dump: the ones the module publishes.
    var summaries: std.ArrayList([]const u8) = .empty;
    if (options.summaries) for (m.contracts, 0..) |c, di| if (c) |x| try summaries.append(arena, try m.summaryText(@intCast(di), x));
    const published = try Contract.publish(gpa, &m.loc, m.contracts, derived, m.js);
    return .{ .lines = try arena.dupe(Line, m.lines.items), .published = published, .limits = m.limits.items, .summaries = summaries.items, .false_words = m.false_words.items };
}
