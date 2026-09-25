//! The checker → backend dispatch table (docs/design/checker-v2.md §13, which
//! replaced static-dispatch-spike.md §7's flat record at slice R2a): one per
//! module, flat, index-based, immutable once built.
//!
//! The backend sees no types (`backend.md` §3), so everything the checker
//! decided about a method call has to cross as DATA. This is that data: a
//! table of evidence TREES. Every instruction that dispatches or passes
//! evidence has one `Site`, holding the function a method call runs (its
//! `callee` term) and one evidence ROOT per requirement of the scheme the
//! instruction instantiates. A term that takes evidence of its own carries it
//! as `args`, a range of further terms, so the shape of the hidden arguments
//! is IN the table and nothing downstream recounts it (§13.3).
//!
//! **Two vocabularies live in this file, and only one crosses.** The v1
//! checker still accumulates what it decides in static-dispatch-spike.md §7's
//! flat form — `Target`, `FlatSite`, `FlatDerived`, numbered by the cursor of
//! §7.2 and ordered by `FlatSite.parent` (A.68) — because `Solve` writes it
//! from inside `unify` and rolls it back by truncation. `Builder.finish` is
//! the ONE place that flat pre-order is interpreted: it converts every
//! instruction's run of flat sites into trees (a legacy `err` part becomes
//! the `undetermined` leaf, a legacy `err` site becomes no term) and hands the
//! backend nothing but the tree record. v2 will write the trees directly
//! (checker-v2.md §12.2) and the flat half goes with v1 (R12).
//!
//! **Sorted before anything indexes it.** `derived` is sorted by emitted name
//! text inside `finish`, and every `derived` term and `Binder.derived`
//! indexes the SORTED table — so the table a dump prints and the table the
//! emitter walks are one table in one order, and `--jobs` cannot move a byte
//! of either (§7.1, A.29, CLAUDE.md rule 5). `sites` is ascending by
//! instruction, one row per instruction.
//!
//! **Acyclic by construction.** Terms are allocated in PRE-ORDER, so every
//! argument's `TermIndex` is greater than its owner's. `cache/dispatch_bytes`
//! verifies that on load, and it is what lets every walker recurse without a
//! guard against a table that points back at itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const ConventionFile = @import("Convention.zig");

pub const Convention = ConventionFile.Convention;

const Dispatch = @This();

pub const Symbol = InternPool.Symbol;
pub const TypeId = TypeStore.TypeId;

/// A half-open run of a sidecar table.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub const empty: Range = .{};
};

/// What a derived function is derived FOR. There is no `prim` shape: a
/// primitive is a term of its own.
pub const Shape = union(enum(u8)) {
    /// A `type`, `opaque type` or `foreign type`.
    nominal: TypeId,
    /// The field names, sorted by name text: a range of `symbols`.
    record: Range,
    /// The arity.
    tuple: u8,
    unit,
};

/// The four comparisons the backend emits as an operator or a synthesised
/// comparator (static-dispatch-spike.md §8.3, §9.1).
pub const Primitive = enum(u8) { strict_eq, num_compare, char_compare, string_compare };

// ---------------------------------------------------------------------------
// The record the backend reads (checker-v2.md §13.1)
// ---------------------------------------------------------------------------

pub const TermIndex = enum(u32) {
    _,

    pub fn int(i: TermIndex) u32 {
        return @intFromEnum(i);
    }

    pub fn toOptional(i: TermIndex) Optional {
        return @enumFromInt(@intFromEnum(i));
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?TermIndex {
            if (o == .none) return null;
            return @enumFromInt(@intFromEnum(o));
        }
    };
};

/// What a `param` term's `k` counts the requirements OF (§13.1, amended by
/// R2a). `decl` carries no index: a site belongs to exactly one declaration,
/// the one whose instruction range holds it.
pub const Binder = union(enum(u8)) {
    decl,
    /// A generalised constrained `let` (D5, R14). Never written before R14.
    let: Bir.Inst.Index,
    /// A derived function's context entry, by SORTED `derived` index.
    derived: u32,
};

/// One node of an evidence tree.
pub const Term = union(enum(u8)) {
    /// The `k`th evidence parameter of an enclosing binder.
    param: Param,
    /// A value of this module, and the evidence this use passes it.
    top: Top,
    /// A value of another module, and the evidence this use passes it.
    ext: Ext,
    /// A derived function THIS module emits (§9.2, A.47), and the evidence
    /// this use passes it — one argument per context entry.
    derived: DerivedUse,
    /// Another module's nominal type's derived function, named
    /// `<Module>$<Type>$$<kind>` (§8.5); it has no row here.
    ext_derived: ExtDerivedUse,
    primitive: Primitive,
    /// §9.4's proven-undetermined default, lowered as the structural answer
    /// (`Basics.eq`, or `num_compare` for `compare`). v1's converter writes
    /// it for a legacy `err` PART, which is exactly how `Lower` answered one
    /// before R2a (checker-v2.md §13.1).
    undetermined,
    /// A record receiver: a plain field call. A callee only.
    field,

    pub const Param = struct { binder: Binder, k: u16 };
    pub const Top = struct { decl: Bir.DeclIndex, args: Range = .empty };
    pub const Ext = struct { module: Graph.Index, value: Interface.ValueIndex, args: Range = .empty };
    pub const DerivedUse = struct { index: u32, args: Range = .empty };
    pub const ExtDerivedUse = struct {
        module: Graph.Index,
        type: TypeId,
        kind: Derived.Kind,
        args: Range = .empty,
    };

    /// The range of `args` this term's own arguments occupy, or empty.
    pub fn argsOf(t: Term) Range {
        return switch (t) {
            .top => |u| u.args,
            .ext => |u| u.args,
            .derived => |u| u.args,
            .ext_derived => |u| u.args,
            else => .empty,
        };
    }
};

/// Everything the checker decided about one instruction.
pub const Site = struct {
    inst: Bir.Inst.Index,
    /// `method_call` and `type_dispatch` only: the function it runs. A
    /// `top`/`ext` callee has no `args` of its own — its evidence is
    /// `evidence` — while a `derived`/`ext_derived` callee carries its
    /// evidence as `args` and `evidence` is empty.
    callee: TermIndex.Optional = .none,
    /// The roots, one per requirement of the instantiated scheme, in
    /// canonical order: a range of `args`.
    evidence: Range = .empty,
};

/// One declaration's hidden parameters, its arity and its calling
/// convention (§13.1, §12.5).
pub const DeclInfo = struct {
    /// A range of `requirements`, in canonical order (spike §7.2).
    requirements: Range = .empty,
    /// The parameter count of the declaration's solved type, 0 for a
    /// non-function.
    value_arity: u16 = 0,
    /// `Convention.of` over this declaration, written by `finish`. Every
    /// consumer reads it through `Convention.ofDecl`.
    convention: Convention = .plain,
};

/// A generalised constrained `let` (D5). The column exists, EMPTY, from R2a,
/// so R14 owes no format bump (N6).
pub const LetInfo = struct { inst: Bir.Inst.Index, requirements: Range };

/// One evidence parameter: which quantifier of its scheme it came from, and
/// which method (spike §7.2's canonical order).
pub const Requirement = struct {
    quantified: u16,
    var_name: Symbol.Optional,
    method: Symbol,
};

/// One evidence parameter of a derived function (D4). v1 writes "one per
/// type parameter, field or element, method = the derived method" — its ABI.
pub const ContextEntry = struct { param: u16, method: Symbol };

/// One function this module emits (§9). Keyed on `(kind, shape)` and NOTHING
/// else: what varies between two uses is the evidence, which rides on the
/// term (A.46).
pub const Derived = struct {
    kind: Kind,
    shape: Shape,
    /// Its evidence parameters: a range of `contexts`.
    context: Range = .empty,
    /// NOMINAL: one term per constructor argument position, constructors in
    /// declaration order, arguments left to right — a range of `args`.
    /// EMPTY for a record, a tuple or `()`, whose body applies `$m$0 …`
    /// position by position by construction (§9.2, §9.3).
    body: Range = .empty,

    pub const Kind = enum(u8) { eq, compare };
};

/// Which shape every `?` of this module turned out to have (`checker.md`
/// §6.5), sorted by instruction.
///
/// **It is a decision and not a lookup, so it has to cross as data.** The
/// backend sees no types, and `Maybe` and `Result` are the one construct
/// where the emitted JavaScript differs by a type the program never wrote.
pub const Try = struct {
    inst: Bir.Inst.Index,
    shape: Kind,

    /// Named `Kind` and not `Shape` because `Shape` above is what a DERIVED
    /// function is derived for.
    pub const Kind = enum(u8) { maybe, result };
};

terms: []const Term = &.{},
/// Term indices: every `args`, `Site.evidence` and `Derived.body` range
/// points in here.
args: []const TermIndex = &.{},
/// Ascending by instruction, at most one per instruction.
sites: []const Site = &.{},
/// One per `Bir.Decl`.
decls: []const DeclInfo = &.{},
/// EMPTY until R14.
lets: []const LetInfo = &.{},
requirements: []const Requirement = &.{},
contexts: []const ContextEntry = &.{},
/// Sorted by emitted name text (§8.5). Exactly the functions this module
/// emits: a derived method of another module's type is an `ext_derived`
/// term and has no row here (A.47).
derived: []const Derived = &.{},
/// One per `try` instruction that solved, ascending by instruction.
tries: []const Try = &.{},
/// The names `Shape.record` ranges over.
symbols: []const Symbol = &.{},

pub const empty: Dispatch = .{};

pub fn deinit(d: *Dispatch, gpa: Allocator) void {
    gpa.free(d.terms);
    gpa.free(d.args);
    gpa.free(d.sites);
    gpa.free(d.decls);
    gpa.free(d.lets);
    gpa.free(d.requirements);
    gpa.free(d.contexts);
    gpa.free(d.derived);
    gpa.free(d.tries);
    gpa.free(d.symbols);
    d.* = .empty;
}

/// Whether the table holds anything at all. A module with no dispatch prints
/// its `module` line and nothing else.
pub fn isEmpty(d: *const Dispatch) bool {
    return d.sites.len == 0 and d.derived.len == 0 and d.requirements.len == 0 and d.tries.len == 0;
}

pub fn term(d: *const Dispatch, i: TermIndex) Term {
    return d.terms[i.int()];
}

pub fn argsAt(d: *const Dispatch, r: Range) []const TermIndex {
    if (r.len == 0) return &.{};
    return d.args[r.start..][0..r.len];
}

/// The arguments of the term at `i`.
pub fn argsOfTerm(d: *const Dispatch, i: TermIndex) []const TermIndex {
    return d.argsAt(d.term(i).argsOf());
}

/// Which shape the `?` at `inst` has, or `null` when the checker recorded
/// none. One binary search over a table with one row per `?`.
pub fn tryShape(d: *const Dispatch, inst: Bir.Inst.Index) ?Try.Kind {
    var lo: usize = 0;
    var hi: usize = d.tries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = d.tries[mid].inst;
        if (at == inst) return d.tries[mid].shape;
        if (at.int() < inst.int()) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// The site of one instruction, or null. One binary search: this runs for
/// every call and every reference the backend lowers.
pub fn siteOf(d: *const Dispatch, inst: Bir.Inst.Index) ?*const Site {
    const r = d.siteRange(inst.int(), inst.int() + 1);
    if (r.len == 0) return null;
    return &d.sites[r.start];
}

/// The sites of the instructions `[start, end)`. A declaration's
/// instructions are contiguous, so its sites are one slice.
pub fn sitesIn(d: *const Dispatch, start: u32, end: u32) []const Site {
    const r = d.siteRange(start, end);
    return d.sites[r.start..][0..r.len];
}

fn siteRange(d: *const Dispatch, start: u32, end: u32) Range {
    const lo = std.sort.lowerBound(Site, d.sites, start, siteBefore);
    var hi = lo;
    while (hi < d.sites.len and d.sites[hi].inst.int() < end) hi += 1;
    return .{ .start = @intCast(lo), .len = @intCast(hi - lo) };
}

fn siteBefore(inst: u32, s: Site) std.math.Order {
    return std.math.order(inst, s.inst.int());
}

/// The evidence parameters of `decl`, in canonical order.
pub fn declRequirements(d: *const Dispatch, decl: u32) []const Requirement {
    if (decl >= d.decls.len) return &.{};
    const r = d.decls[decl].requirements;
    return d.requirements[r.start..][0..r.len];
}

pub fn contextOf(d: *const Dispatch, index: u32) []const ContextEntry {
    if (index >= d.derived.len) return &.{};
    const r = d.derived[index].context;
    return d.contexts[r.start..][0..r.len];
}

/// The field names of a record shape.
pub fn shapeNames(d: *const Dispatch, r: Range) []const Symbol {
    return d.symbols[r.start..][0..r.len];
}

// ---------------------------------------------------------------------------
// Counting, once (I7)
// ---------------------------------------------------------------------------

/// `Convention.of` over declaration `i` of `bir` (checker-v2.md §12.5): its
/// written parameters, whether its entire body is a `lambda`, its type's
/// arity and its evidence. A `foreign` value has neither parameters nor a
/// body, so its type decides, exactly as for an import.
fn conventionOf(bir: *const Bir, i: usize, value_arity: u16, evidence: u32) Convention {
    if (i >= bir.decls.len) return ConventionFile.of(0, false, value_arity, evidence);
    return ConventionFile.of(bir.decls[i].params, ConventionFile.bodyIsLambda(bir, @intCast(i)), value_arity, evidence);
}

/// The requirement count of an imported value, computed from its interface
/// scheme the way spike §7.2's canonical order is: one per constraint of each
/// quantifier. Exporter and importer derive it from the same record, so they
/// agree.
pub fn extRequirementCount(interfaces: []const Interface, module: Graph.Index, value: u32) u32 {
    if (module.int() >= interfaces.len) return 0;
    const iface = &interfaces[module.int()];
    if (value >= iface.values.len) return 0;
    const index = iface.values[value].scheme;
    if (index == .none or @intFromEnum(index) >= iface.schemes.len) return 0;
    const s = iface.scheme(index);
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < s.quantified_count) : (i += 1) n += iface.quantified(s, i).constraints_len;
    return n;
}

/// How many evidence arguments the function a term names takes (I7):
/// `DeclInfo` for a value of this module, the interface scheme for an
/// imported one, the context for a derived function and, for another
/// module's derived function, its type's parameter count — the published
/// context length under v1's ABI (§14.2). Every other term takes none.
///
/// **The one counting function.** `finish`'s assert and `Lower`'s cheap
/// re-assert both call it; nothing else counts evidence.
pub fn requirementCount(d: *const Dispatch, t: Term, interfaces: []const Interface, types: *const Types) u32 {
    return switch (t) {
        .top => |u| @intCast(d.declRequirements(u.decl.int()).len),
        .ext => |u| extRequirementCount(interfaces, u.module, @intFromEnum(u.value)),
        .derived => |u| @intCast(d.contextOf(u.index).len),
        .ext_derived => |u| types.entry(u.type).arity,
        .param, .primitive, .undetermined, .field => 0,
    };
}

/// The requirement count of the value a Bir REFERENCE names: a `top` or an
/// `ext_value`. Anything else — a local, a lambda, a constructor — takes
/// none, because only a top-level declaration has evidence before R14.
pub fn referenceCount(d: *const Dispatch, bir: *const Bir, interfaces: []const Interface, inst: Bir.Inst.Index) u32 {
    if (inst.int() >= bir.insts.len) return 0;
    const data = bir.instData(inst);
    return switch (bir.instTag(inst)) {
        .top => @intCast(d.declRequirements(data.lhs).len),
        .ext_value => extRequirementCount(interfaces, @enumFromInt(data.lhs), data.rhs),
        else => 0,
    };
}

/// I7 (checker-v2.md §2, §13.1): every term's argument count is its callee's
/// requirement count, and every site's root count is the instantiated
/// scheme's. Appends the instruction of every site that breaks it — and, for
/// a derived row whose body does, the type's first instruction — to `out`.
///
/// Also refuses what the tree shape alone cannot say: a `field` anywhere but
/// a callee, an argument whose index does not follow its owner's (the
/// acyclicity rule), a `derived` index past the table, and a
/// `method_call`/`type_dispatch` site with no callee.
///
/// A PREDICATE over the table, with nothing reported: `finish`'s caller
/// turns each instruction into one `internal`, never a panic (S10).
pub fn checkI7(
    d: *const Dispatch,
    bir: *const Bir,
    interfaces: []const Interface,
    types: *const Types,
    gpa: Allocator,
    out: *std.ArrayList(Bir.Inst.Index),
) Allocator.Error!void {
    var cx: I7 = .{ .d = d, .interfaces = interfaces, .types = types };
    const below = try gpa.alloc(bool, d.terms.len);
    defer gpa.free(below);
    var at = d.terms.len;
    while (at > 0) {
        at -= 1;
        below[at] = cx.localOk(below, @intCast(at));
    }
    cx.below = below;
    for (d.derived) |row| {
        var ok = true;
        if (@as(u64, row.body.start) + row.body.len > d.args.len) ok = false;
        if (ok) for (d.argsAt(row.body)) |t| {
            if (!cx.termOk(t, null)) ok = false;
        };
        if (ok) continue;
        var region: Bir.Inst.Index = @enumFromInt(0);
        if (row.shape == .nominal) {
            const entry = types.entry(row.shape.nominal);
            if (entry.decl.int() < bir.decls.len) region = bir.decls[entry.decl.int()].inst_start;
        }
        try out.append(gpa, region);
    }
    // Every instruction the backend reads a site for, in order, with the
    // sites walked beside them: a site that is there must add up, and one
    // that is NOT there is a violation too wherever the Bir needs one — a
    // `method_call`/`type_dispatch` has no function to call without it, and
    // a `call` of a constrained callee would be emitted short of its hidden
    // arguments (`Lower.callExpr` refuses both; this is the same answer one
    // phase earlier, so `check` says what `build` would).
    var next: usize = 0;
    const tags = bir.insts.items(.tag);
    const data = bir.insts.items(.data);
    for (tags, data, 0..) |tag, payload, raw| {
        const inst: Bir.Inst.Index = @enumFromInt(@as(u32, @intCast(raw)));
        while (next < d.sites.len and d.sites[next].inst.int() < inst.int()) : (next += 1) {
            // A site on an instruction past the Bir, or out of order: the
            // loop below never meets it, so it is measured here.
            if (!cx.siteOk(bir, d.sites[next])) try out.append(gpa, d.sites[next].inst);
        }
        if (next < d.sites.len and d.sites[next].inst == inst) {
            if (!cx.siteOk(bir, d.sites[next])) try out.append(gpa, inst);
            next += 1;
            continue;
        }
        const missing = switch (tag) {
            .method_call, .type_dispatch => true,
            .call => referenceCount(d, bir, interfaces, @enumFromInt(payload.lhs)) != 0,
            else => false,
        };
        if (missing) try out.append(gpa, inst);
    }
    for (d.sites[next..]) |site| {
        if (!cx.siteOk(bir, site)) try out.append(gpa, site.inst);
    }
    try cx.placement(bir, gpa, out);
}

/// The method a requirement slot asks for: argument `k` of `owner`, the
/// `k`th requirement of the function it names (a derived function's context
/// entries all ask for its own method under v1's ABI), or null when the
/// owner names none.
fn slotMethod(d: *const Dispatch, interfaces: []const Interface, owner: Term, k: usize) ?Symbol {
    switch (owner) {
        .top => |u| {
            const reqs = d.declRequirements(u.decl.int());
            return if (k < reqs.len) reqs[k].method else null;
        },
        .ext => |u| return extRequirementMethod(interfaces, u.module, @intFromEnum(u.value), k),
        .derived => |u| {
            const ctx = d.contextOf(u.index);
            return if (k < ctx.len) ctx[k].method else null;
        },
        .ext_derived => |u| return kindMethod(u.kind),
        else => return null,
    }
}

fn kindMethod(kind: Derived.Kind) Symbol {
    return switch (kind) {
        .eq => InternPool.WellKnown.eq.symbol(),
        .compare => InternPool.WellKnown.compare.symbol(),
    };
}

/// The method of an imported value's `k`th requirement, in the canonical
/// order `extRequirementCount` counts.
fn extRequirementMethod(interfaces: []const Interface, module: Graph.Index, value: u32, k: usize) ?Symbol {
    if (module.int() >= interfaces.len) return null;
    const iface = &interfaces[module.int()];
    if (value >= iface.values.len) return null;
    const index = iface.values[value].scheme;
    if (index == .none or @intFromEnum(index) >= iface.schemes.len) return null;
    const s = iface.scheme(index);
    var at: usize = 0;
    var i: u32 = 0;
    while (i < s.quantified_count) : (i += 1) {
        const q = iface.quantified(s, i);
        if (k < at + q.constraints_len) return iface.symbol(iface.quantifiedConstraint(q, @intCast(k - at)).name);
        at += q.constraints_len;
    }
    return null;
}

const I7 = struct {
    d: *const Dispatch,
    interfaces: []const Interface,
    types: *const Types,
    /// Per term: it and everything below it add up (`localOk`).
    below: []const bool = &.{},

    fn count(cx: I7, t: Term) u32 {
        return requirementCount(cx.d, t, cx.interfaces, cx.types);
    }

    fn siteOk(cx: I7, bir: *const Bir, site: Site) bool {
        const d = cx.d;
        if (@as(u64, site.evidence.start) + site.evidence.len > d.args.len) return false;
        const tag: ?Bir.Inst.Tag = if (site.inst.int() < bir.insts.len) bir.instTag(site.inst) else null;
        const wants_callee = if (tag) |t| (t == .method_call or t == .type_dispatch) else false;
        for (d.argsAt(site.evidence)) |root| {
            if (!cx.termOk(root, null)) return false;
        }
        if (site.callee.unwrap()) |callee| {
            if (!wants_callee) return false;
            if (callee.int() >= d.terms.len) return false;
            const c = d.term(callee);
            switch (c) {
                // Its evidence is its own arguments; the site passes none.
                .derived, .ext_derived => {
                    if (!cx.termOk(callee, null)) return false;
                    return site.evidence.len == 0;
                },
                // Its evidence is the site's roots.
                .top, .ext => {
                    if (c.argsOf().len != 0) return false;
                    return site.evidence.len == cx.count(c);
                },
                .primitive, .field, .param => return site.evidence.len == 0,
                // Never a callee: an `err` SITE becomes no term at all.
                .undetermined => return false,
            }
        }
        if (wants_callee) return false;
        const t = tag orelse return true;
        const data = bir.instData(site.inst);
        const expected: u32 = switch (t) {
            .call => referenceCount(d, bir, cx.interfaces, @enumFromInt(data.lhs)),
            .top, .ext_value, .local => referenceCount(d, bir, cx.interfaces, site.inst),
            // A site the backend never reads: nothing to measure it against.
            else => return true,
        };
        return site.evidence.len == expected;
    }

    /// `owner` is the term whose argument this is, for the ordering rule.
    fn termOk(cx: I7, i: TermIndex, owner: ?TermIndex) bool {
        if (i.int() >= cx.d.terms.len) return false;
        if (owner) |o| if (i.int() <= o.int()) return false;
        return cx.below[i.int()];
    }

    /// Whether term `i` and everything below it add up, given the answer
    /// for every term after it: one pass from the last term to the first,
    /// so a term SHARED by several owners (checker-v2.md §13.1 as amended by
    /// R6b) is judged once — the recursive walk this replaced was
    /// exponential on a doubling DAG (CK-80).
    fn localOk(cx: I7, below: []const bool, i: u32) bool {
        const d = cx.d;
        const t = d.terms[i];
        const r = t.argsOf();
        if (@as(u64, r.start) + r.len > d.args.len) return false;
        switch (t) {
            .field => return false,
            .derived => |u| if (u.index >= d.derived.len) return false,
            else => {},
        }
        if (r.len != cx.count(t)) return false;
        for (d.argsAt(r)) |arg| {
            if (arg.int() <= i or arg.int() >= d.terms.len) return false;
            if (!below[arg.int()]) return false;
        }
        return true;
    }

    const Visit = struct { term: u32, ctx: u8, method: Symbol.Optional };

    /// Where an `undetermined` leaf may stand (§13.1 as amended by R6b's
    /// review, B1 and CK-103): `Lower` takes its method from the nearest
    /// `derived`/`ext_derived` ancestor (or row, for a body position), so it
    /// must have one, of the method its slot asks for. Everywhere else the
    /// table must name the structural function. Each `(term, ancestor kind,
    /// slot method)` is judged once, so a shared term costs one visit per
    /// context. Appends the instruction of each site, or the type's first
    /// instruction for each row, that breaks it.
    fn placement(cx: I7, bir: *const Bir, gpa: Allocator, out: *std.ArrayList(Bir.Inst.Index)) Allocator.Error!void {
        const d = cx.d;
        var seen: std.AutoHashMapUnmanaged(Visit, void) = .empty;
        defer seen.deinit(gpa);
        var stack: std.ArrayList(Visit) = .empty;
        defer stack.deinit(gpa);
        for (d.derived) |row| {
            if (@as(u64, row.body.start) + row.body.len > d.args.len) continue;
            const kind: u8 = @as(u8, @intFromEnum(row.kind)) + 1;
            const method = kindMethod(row.kind).toOptional();
            stack.clearRetainingCapacity();
            for (d.argsAt(row.body)) |t| try stack.append(gpa, .{ .term = t.int(), .ctx = kind, .method = method });
            if (try cx.placed(&seen, &stack, gpa)) continue;
            var region: Bir.Inst.Index = @enumFromInt(0);
            if (row.shape == .nominal) {
                const entry = cx.types.entry(row.shape.nominal);
                if (entry.decl.int() < bir.decls.len) region = bir.decls[entry.decl.int()].inst_start;
            }
            try out.append(gpa, region);
        }
        for (d.sites) |site| {
            if (@as(u64, site.evidence.start) + site.evidence.len > d.args.len) continue;
            stack.clearRetainingCapacity();
            var owner: ?Term = null;
            if (site.callee.unwrap()) |callee| {
                if (callee.int() >= d.terms.len) continue;
                try stack.append(gpa, .{ .term = callee.int(), .ctx = 0, .method = .none });
                owner = d.term(callee);
            } else if (site.inst.int() < bir.insts.len) {
                var ref = site.inst;
                if (bir.instTag(ref) == .call) ref = @enumFromInt(bir.instData(ref).lhs);
                if (ref.int() < bir.insts.len) {
                    const data = bir.instData(ref);
                    owner = switch (bir.instTag(ref)) {
                        .top => .{ .top = .{ .decl = @enumFromInt(data.lhs) } },
                        .ext_value => .{ .ext = .{ .module = @enumFromInt(data.lhs), .value = @enumFromInt(data.rhs) } },
                        else => null,
                    };
                }
            }
            for (d.argsAt(site.evidence), 0..) |t, k| {
                const method: Symbol.Optional = if (owner) |o| (if (slotMethod(d, cx.interfaces, o, k)) |m| m.toOptional() else .none) else .none;
                try stack.append(gpa, .{ .term = t.int(), .ctx = 0, .method = method });
            }
            if (!try cx.placed(&seen, &stack, gpa)) try out.append(gpa, site.inst);
        }
    }

    fn placed(cx: I7, seen: *std.AutoHashMapUnmanaged(Visit, void), stack: *std.ArrayList(Visit), gpa: Allocator) Allocator.Error!bool {
        const d = cx.d;
        while (stack.pop()) |v| {
            if (v.term >= d.terms.len) continue;
            if ((try seen.getOrPut(gpa, v)).found_existing) continue;
            const t = d.terms[v.term];
            if (t == .undetermined) {
                if (v.ctx == 0) return false;
                const kind: Derived.Kind = @enumFromInt(v.ctx - 1);
                if (v.method.unwrap()) |m| if (m != kindMethod(kind)) return false;
                continue;
            }
            const ctx: u8 = switch (t) {
                .derived => |u| if (u.index < d.derived.len) @as(u8, @intFromEnum(d.derived[u.index].kind)) + 1 else v.ctx,
                .ext_derived => |u| @as(u8, @intFromEnum(u.kind)) + 1,
                else => v.ctx,
            };
            const r = t.argsOf();
            if (@as(u64, r.start) + r.len > d.args.len) continue;
            for (d.argsAt(r), 0..) |arg, k| {
                if (arg.int() <= v.term) continue;
                const method: Symbol.Optional = if (slotMethod(d, cx.interfaces, t, k)) |m| m.toOptional() else .none;
                try stack.append(gpa, .{ .term = arg.int(), .ctx = ctx, .method = method });
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// The v1 builder's flat vocabulary (static-dispatch-spike.md §7.1–§7.2)
// ---------------------------------------------------------------------------

/// Which function a flat site calls, or which value it passes. The v1
/// checker's vocabulary: `finish` converts it into `Term`s.
pub const Target = union(enum(u8)) {
    /// A value of this module, and — in a PART position — the evidence
    /// this use passes it.
    top: TopUse,
    ext: Ext,
    /// The `k`th evidence parameter of the ENCLOSING declaration or, in a
    /// derived row's body, of the derived function.
    evidence: u16,
    primitive: Primitive,
    /// A derived function THIS module emits, and the evidence this use
    /// passes it (§9.2, A.11, A.46).
    derived: DerivedUse,
    /// A derived function of another module's nominal type (A.47).
    ext_derived: ExtDerivedUse,
    /// A record receiver: a plain field call.
    field,
    err,

    /// **A `top` or `ext` in a PART position carries its own evidence**
    /// (§7.1 amendment, A.64). At a call site the evidence of a constrained
    /// value rides on the flat sites that follow it (§8.2); inside a
    /// `parts` tree there is no site to number, so the tree carries it.
    /// EMPTY at a call site.
    pub const TopUse = struct {
        decl: Bir.DeclIndex,
        parts: Range = .empty,
    };

    pub const Ext = struct {
        module: Graph.Index,
        value: Interface.ValueIndex,
        parts: Range = .empty,
    };

    /// **The evidence is per USE, never per function** (A.11, A.46).
    pub const DerivedUse = struct {
        /// Index into the builder's `derived`, in REQUEST order until
        /// `finish` sorts it.
        index: u32,
        /// One `Target` per evidence parameter, in shape order: a range of
        /// `parts`. Recursive.
        parts: Range = .empty,
    };

    pub const ExtDerivedUse = struct {
        module: Graph.Index,
        type: TypeId,
        kind: Derived.Kind,
        parts: Range = .empty,
    };

    /// The evidence arguments this target passes, or an empty range.
    pub fn partsOf(t: Target) Range {
        return switch (t) {
            .derived => |d| d.parts,
            .ext_derived => |d| d.parts,
            .top => |d| d.parts,
            .ext => |e| e.parts,
            else => .empty,
        };
    }
};

/// One slot of one instruction, in v1's flat numbering (spike §7.2).
pub const FlatSite = struct {
    inst: Bir.Inst.Index,
    evidence_index: u16,
    /// Which slot of the same instruction this one hangs under, or
    /// `no_parent` for a slot the instruction owns outright.
    ///
    /// **The list is flat and the tree is real** (§7.2, §8.2). The cursor
    /// that numbers slots runs in ALLOCATION order, which is breadth-first,
    /// so the parent is what `finish` orders the run by before it reads the
    /// run as a pre-order tree (A.68). `evidence_index` is only the identity
    /// the checker's two deduplicating tables key on.
    parent: u16 = no_parent,
    target: Target,

    pub const no_parent: u16 = std.math.maxInt(u16);
};

/// One evidence parameter of an ANNOTATED declaration, keyed by the rigid
/// variable it sits on. Built by `Check` from the annotation's `where`
/// clause in the canonical order of §7.2, so a constraint discharged against
/// a rigid knows which hidden parameter answers it.
pub const RigidEvidence = struct { v: TypeStore.Var, method: Symbol, index: u16 };

/// A derived function as the builder accumulates it.
pub const FlatDerived = struct {
    kind: Derived.Kind,
    shape: Shape,
    /// One evidence parameter per field, element or type parameter, in
    /// shape order (A.20).
    evidence_count: u16 = 0,
    /// A nominal shape's BODY positions, a range of `parts`; empty
    /// otherwise.
    parts: Range = .empty,
};

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

/// Accumulates the flat tables while a module is checked; `finish` sorts
/// them and converts them to the tree record once, at the end of
/// `ModuleCheck.run`.
///
/// Every list here is APPEND-ONLY and rolled back by truncating its length,
/// which is what lets `dischargeMethod` run under a `?` probe (§6.1
/// invariant 2, A.35). `Lengths`/`shrink` are that rollback.
pub const Builder = struct {
    gpa: Allocator,
    sites: std.ArrayList(FlatSite) = .empty,
    tries: std.ArrayList(Try) = .empty,
    evidence: std.ArrayList(Requirement) = .empty,
    derived: std.ArrayList(FlatDerived) = .empty,
    parts: std.ArrayList(Target) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    /// Per declaration, into `evidence`, filled as its rank generalises.
    decl_evidence: std.ArrayList(Range) = .empty,

    pub const Lengths = struct {
        sites: usize,
        /// A `?`'s own shape probe rolls the builder back between its two
        /// guesses (§6.5), so the shapes are rolled back with everything
        /// else — or a retracted guess would decide the emitted test.
        tries: usize,
        evidence: usize,
        derived: usize,
        parts: usize,
        symbols: usize,
    };

    pub fn deinit(b: *Builder) void {
        b.sites.deinit(b.gpa);
        b.tries.deinit(b.gpa);
        b.evidence.deinit(b.gpa);
        b.derived.deinit(b.gpa);
        b.parts.deinit(b.gpa);
        b.symbols.deinit(b.gpa);
        b.decl_evidence.deinit(b.gpa);
    }

    pub fn lengths(b: *const Builder) Lengths {
        return .{
            .sites = b.sites.items.len,
            .tries = b.tries.items.len,
            .evidence = b.evidence.items.len,
            .derived = b.derived.items.len,
            .parts = b.parts.items.len,
            .symbols = b.symbols.items.len,
        };
    }

    pub fn shrink(b: *Builder, to: Lengths) void {
        b.sites.shrinkRetainingCapacity(to.sites);
        b.tries.shrinkRetainingCapacity(to.tries);
        b.evidence.shrinkRetainingCapacity(to.evidence);
        b.derived.shrinkRetainingCapacity(to.derived);
        b.parts.shrinkRetainingCapacity(to.parts);
        b.symbols.shrinkRetainingCapacity(to.symbols);
    }

    pub fn addSite(b: *Builder, site: FlatSite) Allocator.Error!void {
        try b.sites.append(b.gpa, site);
    }

    /// Record the shape a `?` solved as. Appended in the order the solver
    /// reaches them and sorted by `finish`.
    pub fn addTry(b: *Builder, entry: Try) Allocator.Error!void {
        try b.tries.append(b.gpa, entry);
    }

    pub fn addSymbols(b: *Builder, names: []const Symbol) Allocator.Error!Range {
        const start: u32 = @intCast(b.symbols.items.len);
        try b.symbols.appendSlice(b.gpa, names);
        return .{ .start = start, .len = @intCast(names.len) };
    }

    pub fn addParts(b: *Builder, targets: []const Target) Allocator.Error!Range {
        const start: u32 = @intCast(b.parts.items.len);
        try b.parts.appendSlice(b.gpa, targets);
        return .{ .start = start, .len = @intCast(targets.len) };
    }

    /// The index of the derived function for `(kind, shape)`, creating it
    /// when it is new. **Deduplicated on the shape alone** (§9.2, A.11,
    /// A.46).
    pub fn derive(b: *Builder, kind: Derived.Kind, shape: Shape, evidence_count: u16) Allocator.Error!u32 {
        if (b.findDerived(kind, shape)) |existing| return existing;
        const index: u32 = @intCast(b.derived.items.len);
        try b.derived.append(b.gpa, .{ .kind = kind, .shape = shape, .evidence_count = evidence_count });
        return index;
    }

    pub fn findDerived(b: *const Builder, kind: Derived.Kind, shape: Shape) ?u32 {
        for (b.derived.items, 0..) |d, i| {
            if (d.kind == kind and shapeEql(b, d.shape, shape)) return @intCast(i);
        }
        return null;
    }

    /// Give a nominal row the body positions of §9's parts contract. Set
    /// once, by the eager pass of A.23, after the entry exists.
    pub fn setDerivedParts(b: *Builder, index: u32, parts: Range) void {
        b.derived.items[index].parts = parts;
    }

    /// Reserve `n` part slots and return their range, so a recursive
    /// resolution can fill them after the entry that names them exists.
    pub fn reserveParts(b: *Builder, n: usize) Allocator.Error!Range {
        const start: u32 = @intCast(b.parts.items.len);
        try b.parts.appendNTimes(b.gpa, .err, n);
        return .{ .start = start, .len = @intCast(n) };
    }

    pub fn setPart(b: *Builder, range: Range, i: usize, target: Target) void {
        b.parts.items[range.start + i] = target;
    }

    fn shapeEql(b: *const Builder, a: Shape, c: Shape) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(c)) return false;
        return switch (a) {
            .nominal => |t| t == c.nominal,
            .record => |r| blk: {
                const o = c.record;
                if (r.len != o.len) break :blk false;
                break :blk std.mem.eql(
                    Symbol,
                    b.symbols.items[r.start..][0..r.len],
                    b.symbols.items[o.start..][0..o.len],
                );
            },
            .tuple => |n| n == c.tuple,
            .unit => true,
        };
    }

    /// Record one declaration's evidence list and return its range.
    pub fn addEvidence(b: *Builder, items: []const Requirement) Allocator.Error!Range {
        const start: u32 = @intCast(b.evidence.items.len);
        try b.evidence.appendSlice(b.gpa, items);
        return .{ .start = start, .len = @intCast(items.len) };
    }

    pub fn setDeclEvidence(b: *Builder, decl_count: usize, decl: u32, r: Range) Allocator.Error!void {
        while (b.decl_evidence.items.len < decl_count) try b.decl_evidence.append(b.gpa, .{});
        if (decl < b.decl_evidence.items.len) b.decl_evidence.items[decl] = r;
    }

    /// Patch the target of an already-appended site: generalisation's
    /// promoted constraint (§6.4).
    pub fn setSiteTarget(b: *Builder, index: u32, target: Target) void {
        b.sites.items[index].target = target;
    }

    fn declEvidenceLen(b: *const Builder, decl: u32) u32 {
        if (decl >= b.decl_evidence.items.len) return 0;
        return b.decl_evidence.items[decl].len;
    }

    /// What `finish` needs besides the builder: the Bir, to tell a method
    /// call's callee slot from an evidence slot; the interfaces, to count an
    /// imported value's evidence exactly as `Lower` did; and each
    /// declaration's arity for `DeclInfo.value_arity`.
    pub const FinishInput = struct {
        decl_count: usize,
        bir: *const Bir,
        interfaces: []const Interface,
        /// Per declaration; missing entries are 0.
        value_arity: []const u16 = &.{},
        /// To place a refusal inside a derived row at its type's declaration;
        /// without it, instruction 0.
        types: ?*const Types = null,
        /// `derived` names are sorted by `name_of`'s text.
        name_of: *const fn (ctx: *anyopaque, d: FlatDerived, out: *std.ArrayList(u8), a: Allocator) Allocator.Error!void,
        name_ctx: *anyopaque,
    };

    /// Move the tables out, sorted (§7.1, §7.3), and converted to trees.
    ///
    /// `dropped` receives the instruction of every legacy `err` SITE the
    /// converter turned into no term (checker-v2.md §13.1): in a module that
    /// reported no error, each is the unreported `err` of queue row 75, and
    /// the caller reports it with the I7 violations.
    pub fn finish(
        b: *Builder,
        gpa: Allocator,
        scratch: Allocator,
        in: FinishInput,
        dropped: *std.ArrayList(Bir.Inst.Index),
    ) Allocator.Error!Dispatch {
        // `derived` is sorted first, because everything else indexes it.
        const n = b.derived.items.len;
        const order = try scratch.alloc(u32, n);
        defer scratch.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        var names = try scratch.alloc([]const u8, n);
        defer {
            for (names) |name| scratch.free(name);
            scratch.free(names);
        }
        for (b.derived.items, 0..) |d, i| {
            var buf: std.ArrayList(u8) = .empty;
            try in.name_of(in.name_ctx, d, &buf, scratch);
            names[i] = try buf.toOwnedSlice(scratch);
        }
        const Sorter = struct {
            names: [][]const u8,
            fn lessThan(self: @This(), x: u32, y: u32) bool {
                return switch (std.mem.order(u8, self.names[x], self.names[y])) {
                    .lt => true,
                    .gt => false,
                    .eq => x < y,
                };
            }
        };
        std.mem.sort(u32, order, Sorter{ .names = names }, Sorter.lessThan);
        const remap = try scratch.alloc(u32, n);
        defer scratch.free(remap);
        for (order, 0..) |old, new| remap[old] = @intCast(new);

        const flat = try scratch.dupe(FlatSite, b.sites.items);
        defer scratch.free(flat);
        std.mem.sort(FlatSite, flat, {}, siteLessThan);
        try preorderSites(flat, scratch);

        while (b.decl_evidence.items.len < in.decl_count) try b.decl_evidence.append(b.gpa, .{});

        var cv: Converter = .{
            .b = b,
            .in = in,
            .remap = remap,
            .gpa = gpa,
            .scratch = scratch,
            .dropped = dropped,
        };
        defer cv.stack.deinit(scratch);
        errdefer {
            cv.terms.deinit(gpa);
            cv.args.deinit(gpa);
            cv.contexts.deinit(gpa);
        }

        // The derived rows, in their SORTED order: context, then body.
        const derived = try gpa.alloc(Derived, n);
        errdefer gpa.free(derived);
        for (order, 0..) |old, new| {
            const row = b.derived.items[old];
            const context_start: u32 = @intCast(cv.contexts.items.len);
            const method = switch (row.kind) {
                .eq => InternPool.WellKnown.eq.symbol(),
                .compare => InternPool.WellKnown.compare.symbol(),
            };
            for (0..row.evidence_count) |k| {
                try cv.contexts.append(gpa, .{ .param = @intCast(k), .method = method });
            }
            cv.region = rowRegion(in, row.shape);
            const body = try cv.partList(row.parts, .{ .derived = @intCast(new) });
            derived[new] = .{
                .kind = row.kind,
                .shape = row.shape,
                .context = .{ .start = context_start, .len = row.evidence_count },
                .body = body,
            };
        }

        // The sites, one per instruction.
        var sites: std.ArrayList(Site) = .empty;
        errdefer sites.deinit(gpa);
        var start: usize = 0;
        while (start < flat.len) {
            var end = start + 1;
            while (end < flat.len and flat[end].inst == flat[start].inst) end += 1;
            try sites.append(gpa, try cv.site(flat[start..end]));
            start = end;
        }

        // One row per `?`, ascending, so the emitter can search it.
        const tries = try gpa.dupe(Try, b.tries.items);
        errdefer gpa.free(tries);
        std.mem.sort(Try, tries, {}, tryLessThan);

        const decls = try gpa.alloc(DeclInfo, in.decl_count);
        errdefer gpa.free(decls);
        for (decls, 0..) |*info, i| {
            const requirements: Range = if (i < b.decl_evidence.items.len) b.decl_evidence.items[i] else .empty;
            const value_arity: u16 = if (i < in.value_arity.len) in.value_arity[i] else 0;
            info.* = .{
                .requirements = requirements,
                .value_arity = value_arity,
                .convention = conventionOf(in.bir, i, value_arity, requirements.len),
            };
        }

        const requirements = try gpa.dupe(Requirement, b.evidence.items);
        errdefer gpa.free(requirements);
        const symbols = try gpa.dupe(Symbol, b.symbols.items);
        errdefer gpa.free(symbols);
        const site_rows = try sites.toOwnedSlice(gpa);
        errdefer gpa.free(site_rows);
        const terms = try cv.terms.toOwnedSlice(gpa);
        errdefer gpa.free(terms);
        const args = try cv.args.toOwnedSlice(gpa);
        errdefer gpa.free(args);
        const contexts = try cv.contexts.toOwnedSlice(gpa);
        return .{
            .terms = terms,
            .args = args,
            .sites = site_rows,
            .decls = decls,
            .lets = &.{},
            .requirements = requirements,
            .contexts = contexts,
            .derived = derived,
            .tries = tries,
            .symbols = symbols,
        };
    }

    /// The first instruction of the type declaration a nominal row derives
    /// for, which is where `checkI7` places a row's refusal too.
    fn rowRegion(in: FinishInput, shape: Shape) Bir.Inst.Index {
        const types = in.types orelse return @enumFromInt(0);
        if (shape != .nominal) return @enumFromInt(0);
        const entry = types.entry(shape.nominal);
        if (entry.decl.int() >= in.bir.decls.len) return @enumFromInt(0);
        return in.bir.decls[entry.decl.int()].inst_start;
    }

    fn tryLessThan(_: void, a: Try, c: Try) bool {
        return a.inst.int() < c.inst.int();
    }

    fn siteLessThan(_: void, a: FlatSite, c: FlatSite) bool {
        if (a.inst != c.inst) return a.inst.int() < c.inst.int();
        return a.evidence_index < c.evidence_index;
    }

    /// Put each instruction's slots into the PRE-ORDER of §7.2's evidence
    /// tree, which is the order the converter reads the flat run in.
    ///
    /// Called on a list already sorted by `(inst, evidence_index)`, so the
    /// instructions are contiguous and within one instruction a slot's
    /// parent, numbered before it was, always sits EARLIER in the group.
    /// Each slot's path from its root is its parent's path with its own
    /// index appended, and sorting the group by that path lexicographically
    /// is the pre-order. Deterministic: the paths are a function of the site
    /// list alone and ties fall back on the position (CLAUDE.md rule 5).
    fn preorderSites(sites: []FlatSite, scratch: Allocator) Allocator.Error!void {
        var start: usize = 0;
        while (start < sites.len) {
            var end = start + 1;
            while (end < sites.len and sites[end].inst == sites[start].inst) end += 1;
            try preorderGroup(sites[start..end], scratch);
            start = end;
        }
    }

    fn preorderGroup(group: []FlatSite, scratch: Allocator) Allocator.Error!void {
        if (group.len < 2) return;

        var flat: std.ArrayList(u16) = .empty;
        defer flat.deinit(scratch);
        const paths = try scratch.alloc(Range, group.len);
        defer scratch.free(paths);
        for (group, 0..) |s, i| {
            const parent: ?usize = if (s.parent == FlatSite.no_parent) null else slotAt(group[0..i], s.parent);
            const inherited: Range = if (parent) |j| paths[j] else .empty;
            try flat.ensureUnusedCapacity(scratch, inherited.len + 1);
            flat.appendSliceAssumeCapacity(flat.items[inherited.start..][0..inherited.len]);
            flat.appendAssumeCapacity(s.evidence_index);
            paths[i] = .{ .start = @intCast(flat.items.len - inherited.len - 1), .len = inherited.len + 1 };
        }

        const order = try scratch.alloc(u32, group.len);
        defer scratch.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const Sorter = struct {
            flat: []const u16,
            paths: []const Range,
            fn lessThan(self: @This(), x: u32, y: u32) bool {
                const a = self.flat[self.paths[x].start..][0..self.paths[x].len];
                const c = self.flat[self.paths[y].start..][0..self.paths[y].len];
                for (a[0..@min(a.len, c.len)], c[0..@min(a.len, c.len)]) |p, q| {
                    if (p != q) return p < q;
                }
                if (a.len != c.len) return a.len < c.len;
                return x < y;
            }
        };
        std.mem.sort(u32, order, Sorter{ .flat = flat.items, .paths = paths }, Sorter.lessThan);

        const sorted = try scratch.alloc(FlatSite, group.len);
        defer scratch.free(sorted);
        for (order, 0..) |old, new| sorted[new] = group[old];
        @memcpy(group, sorted);
    }

    /// Where in `group` the slot numbered `index` sits.
    fn slotAt(group: []const FlatSite, index: u16) ?usize {
        var i = group.len;
        while (i > 0) {
            i -= 1;
            if (group[i].evidence_index == index) return i;
        }
        return null;
    }
};

/// The ONE place v1's flat pre-order is interpreted (checker-v2.md §13.1,
/// R2a). It reads a run exactly as `Lower.evidenceArguments` did before R2a,
/// so the emitted JavaScript cannot move:
///
///   - a `method_call`/`type_dispatch`'s slot 0 is its callee, and every
///     further ROOT of the run is one hidden argument;
///   - a target carrying `parts` (a derived function always, a `top`/`ext`
///     in a part position) is answered by them and consumes no further slot;
///   - any other target consumes, as its own arguments, the next `n` slots
///     — `n` its requirement count, from `decl_evidence` or the interface —
///     each read the same way, recursively;
///   - an `err` part is the `undetermined` leaf; an `err` slot is no term,
///     and its instruction goes to `dropped`.
///
/// A run whose counts do not consume it exactly still converts — with a
/// root too many or an argument too few — and `checkI7` is what says so.
const Converter = struct {
    b: *const Builder,
    in: Builder.FinishInput,
    remap: []const u32,
    gpa: Allocator,
    scratch: Allocator,
    dropped: *std.ArrayList(Bir.Inst.Index),
    terms: std.ArrayList(Term) = .empty,
    args: std.ArrayList(TermIndex) = .empty,
    contexts: std.ArrayList(ContextEntry) = .empty,
    /// Children collected for the term being built, above a mark. A child's
    /// own children are pushed and popped above it before it is pushed, so
    /// each term's run stays contiguous.
    stack: std.ArrayList(TermIndex) = .empty,

    /// Where a refusal from inside the walk is reported: the site's
    /// instruction, or a derived row's type declaration.
    region: Bir.Inst.Index = @enumFromInt(0),

    // **No depth cap that writes a term** (review of R2a, B1). A legacy
    // `parts` range nests forward — each is reserved by the resolution
    // that fills it, never inside itself — so a chain is no deeper than the
    // resolution that built it, and a 4 096-deep one converts fine. A cap
    // that answered `undetermined` past it compiled `Basics.eq` into the
    // bottom of a 1 024-deep `List.eq` chain: a silent wrong answer. The one
    // bound left is the count of `parts` itself, which a forward chain
    // cannot exceed; exceeding it means the builder made a cycle, and that
    // is refused through `dropped` (an `internal`), never a leaf.

    /// Reserve a term slot BEFORE its children, which is the pre-order that
    /// makes every argument index greater than its owner's.
    fn reserve(cv: *Converter) Allocator.Error!TermIndex {
        const at: TermIndex = @enumFromInt(@as(u32, @intCast(cv.terms.items.len)));
        try cv.terms.append(cv.gpa, .undetermined);
        return at;
    }

    /// Move the children above `mark` into `args` and return their range.
    fn popArgs(cv: *Converter, mark: usize) Allocator.Error!Range {
        const children = cv.stack.items[mark..];
        const start: u32 = @intCast(cv.args.items.len);
        try cv.args.appendSlice(cv.gpa, children);
        const r: Range = .{ .start = start, .len = @intCast(children.len) };
        cv.stack.shrinkRetainingCapacity(mark);
        return r;
    }

    /// A list of parts, as a range of `args`.
    fn partList(cv: *Converter, r: Range, binder: Binder) Allocator.Error!Range {
        const mark = cv.stack.items.len;
        for (0..r.len) |i| {
            const t = try cv.part(cv.b.parts.items[r.start + i], binder, 0);
            try cv.stack.append(cv.scratch, t);
        }
        return cv.popArgs(mark);
    }

    /// A target in a PART position: its arguments are its own `parts`.
    fn part(cv: *Converter, t: Target, binder: Binder, depth: u32) Allocator.Error!TermIndex {
        const at = try cv.reserve();
        if (t == .err) return at; // `undetermined`
        if (depth > cv.b.parts.items.len) {
            // A cycle in the builder's ranges: refused, never answered.
            try cv.dropped.append(cv.scratch, cv.region);
            return at;
        }
        const mark = cv.stack.items.len;
        const parts = t.partsOf();
        for (0..parts.len) |i| {
            const child = try cv.part(cv.b.parts.items[parts.start + i], binder, depth + 1);
            try cv.stack.append(cv.scratch, child);
        }
        const r = try cv.popArgs(mark);
        cv.terms.items[at.int()] = cv.termOf(t, binder, r);
        return at;
    }

    /// The term for a non-`err` target, given its arguments.
    fn termOf(cv: *const Converter, t: Target, binder: Binder, r: Range) Term {
        return switch (t) {
            .top => |u| .{ .top = .{ .decl = u.decl, .args = r } },
            .ext => |u| .{ .ext = .{ .module = u.module, .value = u.value, .args = r } },
            .evidence => |k| .{ .param = .{ .binder = binder, .k = k } },
            .primitive => |p| .{ .primitive = p },
            .derived => |u| .{ .derived = .{
                .index = if (u.index < cv.remap.len) cv.remap[u.index] else u.index,
                .args = r,
            } },
            .ext_derived => |u| .{ .ext_derived = .{ .module = u.module, .type = u.type, .kind = u.kind, .args = r } },
            .field => .field,
            .err => .undetermined,
        };
    }

    /// How many further flat slots a target consumes: `Lower.targetEvidence`
    /// as it was.
    fn consumes(cv: *const Converter, t: Target) u32 {
        return switch (t) {
            .top => |u| cv.b.declEvidenceLen(u.decl.int()),
            .ext => |e| extRequirementCount(cv.in.interfaces, e.module, @intFromEnum(e.value)),
            else => 0,
        };
    }

    /// One instruction's run, already in pre-order.
    fn site(cv: *Converter, group: []const FlatSite) Allocator.Error!Site {
        const inst = group[0].inst;
        cv.region = inst;
        const bir = cv.in.bir;
        const tag: ?Bir.Inst.Tag = if (inst.int() < bir.insts.len) bir.instTag(inst) else null;
        const has_callee = if (tag) |t| (t == .method_call or t == .type_dispatch) else false;
        var cursor: usize = 0;
        var callee: TermIndex.Optional = .none;
        if (has_callee and group[0].evidence_index == 0) {
            const t = group[0].target;
            cursor = 1;
            if (t == .err) {
                try cv.dropped.append(cv.scratch, inst);
            } else {
                // A callee's own `parts` are its arguments; it consumes no
                // slot — the rest of the run is the call's roots.
                callee = (try cv.part(t, .decl, 0)).toOptional();
            }
        }
        const mark = cv.stack.items.len;
        while (cursor < group.len) {
            if (try cv.slot(group, &cursor, inst)) |root| try cv.stack.append(cv.scratch, root);
        }
        return .{ .inst = inst, .callee = callee, .evidence = try cv.popArgs(mark) };
    }

    /// One slot and everything it consumes, or null for an `err` slot.
    fn slot(cv: *Converter, group: []const FlatSite, cursor: *usize, inst: Bir.Inst.Index) Allocator.Error!?TermIndex {
        const t = group[cursor.*].target;
        cursor.* += 1;
        if (t == .err) {
            try cv.dropped.append(cv.scratch, inst);
            return null;
        }
        switch (t) {
            .derived, .ext_derived => return try cv.part(t, .decl, 0),
            else => if (t.partsOf().len != 0) return try cv.part(t, .decl, 0),
        }
        const at = try cv.reserve();
        const mark = cv.stack.items.len;
        const wanted = cv.consumes(t);
        var k: u32 = 0;
        while (k < wanted and cursor.* < group.len) : (k += 1) {
            if (try cv.slot(group, cursor, inst)) |child| try cv.stack.append(cv.scratch, child);
        }
        const r = try cv.popArgs(mark);
        cv.terms.items[at.int()] = cv.termOf(t, .decl, r);
        return at;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the builder's lengths and shrink are an exact rollback" {
    // static-dispatch-spike.md §6.1 invariant 2 and A.35: §6.2 registers
    // obligations from inside `unify`, so `dischargeMethod` — and every
    // site it appends — can run under the `?` probe of `checker.md` §6.5
    // and be retracted.
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();

    const before = b.lengths();
    try testing.expectEqual(@as(usize, 0), before.sites);

    const shape_names = try b.addSymbols(&.{ @enumFromInt(3), @enumFromInt(4) });
    const index = try b.derive(.eq, .{ .record = shape_names }, 2);
    const parts = try b.reserveParts(2);
    b.setPart(parts, 0, .{ .primitive = .strict_eq });
    b.setPart(parts, 1, .{ .primitive = .strict_eq });
    try b.addSite(.{ .inst = @enumFromInt(7), .evidence_index = 0, .target = .{ .derived = .{ .index = index, .parts = parts } } });
    _ = try b.addEvidence(&.{.{ .quantified = 0, .var_name = .none, .method = @enumFromInt(9) }});

    const after = b.lengths();
    try testing.expect(after.sites > before.sites);
    try testing.expect(after.derived > before.derived);
    try testing.expect(after.parts > before.parts);
    try testing.expect(after.symbols > before.symbols);
    try testing.expect(b.evidence.items.len > 0);

    b.shrink(before);
    const rolled = b.lengths();
    try testing.expectEqual(before.sites, rolled.sites);
    try testing.expectEqual(before.derived, rolled.derived);
    try testing.expectEqual(before.parts, rolled.parts);
    try testing.expectEqual(before.symbols, rolled.symbols);
    try testing.expectEqual(before.evidence, rolled.evidence);
    _ = try b.derive(.compare, .unit, 0);
    try testing.expectEqual(@as(usize, 1), b.derived.items.len);
}

test "a derived function is deduplicated on its shape alone" {
    // A.11 and A.46: `{ x : Int, y : Int }` and `{ x : String, y : String }`
    // are ONE function with two evidence parameters.
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();
    const names = try b.addSymbols(&.{ @enumFromInt(1), @enumFromInt(2) });
    const again = try b.addSymbols(&.{ @enumFromInt(1), @enumFromInt(2) });
    const first = try b.derive(.eq, .{ .record = names }, 2);
    const second = try b.derive(.eq, .{ .record = again }, 2);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), b.derived.items.len);
    try testing.expect(try b.derive(.compare, .{ .record = names }, 2) != first);
}

/// A Bir of `n` `call` instructions whose callee is instruction 0 (an `int`),
/// so every site on them is a root list measured against a count of 0 — the
/// tests below read the SHAPE of the trees, not the counts.
const TestBir = struct {
    insts: Bir.InstList = .empty,
    bir: Bir = .empty,

    fn init(t: *TestBir, n: usize, tags: []const struct { usize, Bir.Inst.Tag }) !void {
        for (0..n) |i| {
            var tag: Bir.Inst.Tag = if (i == 0) .int else .call;
            for (tags) |pair| if (pair[0] == i) {
                tag = pair[1];
            };
            try t.insts.append(testing.allocator, .{ .tag = tag, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });
        }
        t.bir.insts = t.insts.slice();
    }

    fn deinit(t: *TestBir) void {
        t.insts.deinit(testing.allocator);
    }
};

fn noName(_: *anyopaque, _: FlatDerived, _: *std.ArrayList(u8), _: Allocator) Allocator.Error!void {}

fn finishForTest(b: *Builder, bir: *const Bir, decl_count: usize, dropped: *std.ArrayList(Bir.Inst.Index)) !Dispatch {
    var ctx: u8 = 0;
    return b.finish(testing.allocator, testing.allocator, .{
        .decl_count = decl_count,
        .bir = bir,
        .interfaces = &.{},
        .name_of = noName,
        .name_ctx = &ctx,
    }, dropped);
}

test "the converter reads a breadth-first numbering as the pre-order tree it is" {
    // static-dispatch-spike.md §7.2 and A.68 (`dispatch/TwoSlotsNested`):
    // `pair [ [ 1 ] ] [ [ 2 ] ]` under `pair : a, b -> Bool where a.eq, b.eq`
    // numbers `a` and `b` together, then their children, then their
    // grandchildren. Declaration 0 takes ONE evidence argument, so a `top 0`
    // slot consumes the slot after it: each root is a three-deep chain.
    var tb: TestBir = .{};
    defer tb.deinit();
    try tb.init(10, &.{});
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();
    try b.setDeclEvidence(1, 0, try b.addEvidence(&.{.{ .quantified = 0, .var_name = .none, .method = @enumFromInt(1) }}));

    // 0:a 1:b 2:a's child 3:b's child 4:a's grandchild 5:b's grandchild,
    // appended breadth-first, plus one site of a LATER-sorting but
    // EARLIER-numbered instruction to prove grouping survives.
    const parents = [_]u16{ FlatSite.no_parent, FlatSite.no_parent, 0, 1, 2, 3 };
    for (parents, 0..) |parent, i| {
        const target: Target = if (i >= 4) .{ .primitive = .strict_eq } else .{ .top = .{ .decl = @enumFromInt(0) } };
        try b.addSite(.{ .inst = @enumFromInt(9), .evidence_index = @intCast(i), .parent = parent, .target = target });
    }
    try b.addSite(.{ .inst = @enumFromInt(4), .evidence_index = 0, .target = .{ .evidence = 3 } });

    var dropped: std.ArrayList(Bir.Inst.Index) = .empty;
    defer dropped.deinit(testing.allocator);
    var d = try finishForTest(&b, &tb.bir, 1, &dropped);
    defer d.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), dropped.items.len);
    try testing.expectEqual(@as(usize, 2), d.sites.len);
    try testing.expectEqual(@as(u32, 4), d.sites[0].inst.int());
    const first = d.argsAt(d.sites[0].evidence);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqual(@as(u16, 3), d.term(first[0]).param.k);

    // Two roots, each `top 0 (top 0 (primitive))`.
    const roots = d.argsAt(d.sites[1].evidence);
    try testing.expectEqual(@as(usize, 2), roots.len);
    for (roots) |root| {
        try testing.expect(d.term(root) == .top);
        const child = d.argsOfTerm(root);
        try testing.expectEqual(@as(usize, 1), child.len);
        try testing.expect(d.term(child[0]) == .top);
        const grandchild = d.argsOfTerm(child[0]);
        try testing.expectEqual(@as(usize, 1), grandchild.len);
        try testing.expect(d.term(grandchild[0]) == .primitive);
        try testing.expectEqual(@as(usize, 0), d.argsOfTerm(grandchild[0]).len);
        // Pre-order: every argument follows its owner.
        try testing.expect(child[0].int() > root.int());
        try testing.expect(grandchild[0].int() > child[0].int());
    }
}

test "an err part is undetermined, an err site is no term, and a method call's slot 0 is its callee" {
    var tb: TestBir = .{};
    defer tb.deinit();
    try tb.init(4, &.{.{ 2, .method_call }});
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();

    const parts = try b.reserveParts(2);
    b.setPart(parts, 0, .{ .primitive = .strict_eq });
    // part 1 stays `err`.
    const index = try b.derive(.eq, .{ .tuple = 2 }, 2);
    try b.addSite(.{ .inst = @enumFromInt(2), .evidence_index = 0, .target = .{ .derived = .{ .index = index, .parts = parts } } });
    // An `err` evidence slot on a plain call: no term, and reported.
    try b.addSite(.{ .inst = @enumFromInt(3), .evidence_index = 0, .target = .err });

    var dropped: std.ArrayList(Bir.Inst.Index) = .empty;
    defer dropped.deinit(testing.allocator);
    var d = try finishForTest(&b, &tb.bir, 0, &dropped);
    defer d.deinit(testing.allocator);

    const call = d.siteOf(@enumFromInt(2)).?;
    const callee = d.term(call.callee.unwrap().?);
    try testing.expect(callee == .derived);
    try testing.expectEqual(@as(u32, 0), call.evidence.len);
    const args = d.argsAt(callee.derived.args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expect(d.term(args[0]) == .primitive);
    try testing.expect(d.term(args[1]) == .undetermined);
    // The derived row's context is one entry per evidence parameter, the
    // derived method each (v1's ABI).
    try testing.expectEqual(@as(usize, 2), d.contextOf(0).len);
    try testing.expectEqual(InternPool.WellKnown.eq.symbol(), d.contextOf(0)[1].method);

    const plain = d.siteOf(@enumFromInt(3)).?;
    try testing.expectEqual(@as(u32, 0), plain.evidence.len);
    try testing.expectEqual(@as(usize, 1), dropped.items.len);
    try testing.expectEqual(@as(u32, 3), dropped.items[0].int());
}

test "the I7 assert refuses a hand-corrupted table and accepts the table it came from" {
    // checker-v2.md §13.1: `finish` asserts I7 and its caller reports each
    // violation as `internal`, never a panic (S10). A PREDICATE here, so the
    // corruption can be made by hand: one argument too few, one root too
    // many, an argument that points BACK at its owner, and a method call
    // with no callee.
    var tb: TestBir = .{};
    defer tb.deinit();
    // inst 1: `top` reference to declaration 0; inst 2: a call of inst 1;
    // inst 3: a method call.
    try tb.init(4, &.{ .{ 1, .top }, .{ 3, .method_call } });
    tb.insts.items(.data)[2] = .{ .lhs = 1, .rhs = 0 };
    tb.bir.insts = tb.insts.slice();

    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();
    try b.setDeclEvidence(1, 0, try b.addEvidence(&.{.{ .quantified = 0, .var_name = .none, .method = @enumFromInt(1) }}));
    // A correct table: the call passes declaration 0 its one argument,
    // which is itself `top 0` applied to a primitive.
    try b.addSite(.{ .inst = @enumFromInt(2), .evidence_index = 0, .target = .{ .top = .{ .decl = @enumFromInt(0) } } });
    try b.addSite(.{ .inst = @enumFromInt(2), .evidence_index = 1, .parent = 0, .target = .{ .primitive = .strict_eq } });
    try b.addSite(.{ .inst = @enumFromInt(3), .evidence_index = 0, .target = .{ .primitive = .strict_eq } });

    var dropped: std.ArrayList(Bir.Inst.Index) = .empty;
    defer dropped.deinit(testing.allocator);
    var d = try finishForTest(&b, &tb.bir, 1, &dropped);
    defer d.deinit(testing.allocator);

    var types: Types = .empty;
    var bad: std.ArrayList(Bir.Inst.Index) = .empty;
    defer bad.deinit(testing.allocator);
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 0), bad.items.len);

    // 1. One argument too few: the nested `top 0` loses its argument.
    const roots = d.argsAt(d.sites[0].evidence);
    const nested = d.argsOfTerm(roots[0])[0];
    const terms = @constCast(d.terms);
    const saved = terms[nested.int()];
    terms[nested.int()] = .{ .top = .{ .decl = @enumFromInt(0) } };
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    try testing.expectEqual(@as(u32, 2), bad.items[0].int());
    terms[nested.int()] = saved;
    bad.clearRetainingCapacity();

    // 2. An argument that points back at its owner: a cycle the ordering
    //    rule refuses before any walk could spin on it.
    const args = @constCast(d.args);
    const arg_at = d.term(roots[0]).argsOf().start;
    const saved_arg = args[arg_at];
    args[arg_at] = roots[0];
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    args[arg_at] = saved_arg;
    bad.clearRetainingCapacity();

    // 3. A root too many: the call claims two roots for a one-requirement
    //    callee.
    const sites = @constCast(d.sites);
    sites[0].evidence.len += 1;
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    sites[0].evidence.len -= 1;
    bad.clearRetainingCapacity();

    // 4. A method call with no callee.
    const saved_callee = sites[1].callee;
    sites[1].callee = .none;
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    try testing.expectEqual(@as(u32, 3), bad.items[0].int());
    sites[1].callee = saved_callee;
    bad.clearRetainingCapacity();

    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 0), bad.items.len);
}

test "the I7 assert accepts a term shared by two owners and judges it once" {
    // checker-v2.md §13.1 as amended by R6b: a table may share a term (a DAG
    // whose every argument still follows every owner). Declaration 0 takes
    // two requirements; the call passes two roots, each `derived 0` (one
    // context entry) over the SAME primitive term.
    var tb: TestBir = .{};
    defer tb.deinit();
    try tb.init(3, &.{.{ 1, .top }});
    tb.insts.items(.data)[2] = .{ .lhs = 1, .rhs = 0 };
    tb.bir.insts = tb.insts.slice();
    const requirement: Requirement = .{ .quantified = 0, .var_name = .none, .method = @enumFromInt(1) };
    const requirements = [_]Requirement{ requirement, requirement };
    const decls = [_]DeclInfo{.{ .requirements = .{ .start = 0, .len = 2 } }};
    const contexts = [_]ContextEntry{.{ .param = 0, .method = InternPool.WellKnown.eq.symbol() }};
    const derived = [_]Derived{.{ .kind = .eq, .shape = .unit, .context = .{ .start = 0, .len = 1 } }};
    const terms = [_]Term{
        .{ .derived = .{ .index = 0, .args = .{ .start = 2, .len = 1 } } },
        .{ .derived = .{ .index = 0, .args = .{ .start = 3, .len = 1 } } },
        .{ .primitive = .strict_eq },
    };
    var args = [_]TermIndex{ @enumFromInt(0), @enumFromInt(1), @enumFromInt(2), @enumFromInt(2) };
    const sites = [_]Site{.{ .inst = @enumFromInt(2), .evidence = .{ .start = 0, .len = 2 } }};
    var d: Dispatch = .empty;
    d.terms = &terms;
    d.args = &args;
    d.sites = &sites;
    d.decls = &decls;
    d.requirements = &requirements;
    d.contexts = &contexts;
    d.derived = &derived;

    var types: Types = .empty;
    var bad: std.ArrayList(Bir.Inst.Index) = .empty;
    defer bad.deinit(testing.allocator);
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 0), bad.items.len);

    // The shared term pointing back at an owner is still refused.
    args[3] = @enumFromInt(1);
    try d.checkI7(&tb.bir, &.{}, &types, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    try testing.expectEqual(@as(u32, 2), bad.items[0].int());
}
