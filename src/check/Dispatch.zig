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
//! **One vocabulary.** Until R12 a second one lived here too: v1's flat form
//! of static-dispatch-spike.md §7 (`Target`, `FlatSite`, `FlatDerived` and
//! the `Builder` whose `finish` converted them into trees). It went with v1;
//! the checker writes the trees directly (checker-v2.md §12.2, `Unit.zig`).
//!
//! **Sorted before anything indexes it.** `derived` is sorted by emitted name
//! text before the table is published, and every `derived` term and `Binder.derived`
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
    /// (`Basics.eq`, or `num_compare` for `compare`). v1's converter wrote
    /// it for a legacy `err` PART, which is exactly how `Lower` answered one
    /// before R2a (checker-v2.md §13.1).
    undetermined,
    /// A record receiver: a plain field call. A callee only.
    field,

    /// `k` is a `u32` since dispatch format 4 (R8a's reviews): a derived row
    /// can have more than 65 535 context entries or positions.
    pub const Param = struct { binder: Binder, k: u32 };
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
    /// `Convention.of` over this declaration, written by `Module.zig` (P6). Every
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
pub const ContextEntry = struct {
    /// A `u32` since dispatch format 4 (checker-v2.md §11.2 *as built by
    /// R8a*, CK-82): a structural row has one entry per position, and a
    /// record past 65 535 fields has more positions than a `u16` counts.
    param: u32,
    method: Symbol,
};

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

/// Another module's derived `kind` of type `id`, as its declaring module
/// published it (checker-v2.md §14.2 *as amended by R8a*): the record and
/// the context range of its row — exported or hidden — or null when the
/// record has none. A record the checker writes has a row for every type
/// it can reach (§14.2), so a null is a record that disagrees with the term
/// that names the type. Until R12 a null read as v1's ABI — one entry per
/// type parameter, each the derived method — because v1's records had no
/// hidden rows; R12 deleted v1, and a null now counts no evidence, which
/// I7 then refuses as `internal` rather than answering for a record no
/// checker wrote.
pub fn publishedContext(interfaces: []const Interface, types: *const Types, interner: *const InternPool.Global, id: TypeId, kind: Derived.Kind) ?struct { iface: *const Interface, row: Interface.Derived } {
    if (id == .none) return null;
    const entry = types.entry(id);
    if (entry.module.int() >= interfaces.len) return null;
    const iface = &interfaces[entry.module.int()];
    const facts = iface.typeFacts(interner, entry.name) orelse return null;
    return .{ .iface = iface, .row = facts.derived(switch (kind) {
        .eq => .eq,
        .compare => .compare,
    }) };
}

/// How many evidence parameters another module's derived function takes:
/// its published context's length, or none when there is no row.
pub fn publishedCount(interfaces: []const Interface, types: *const Types, interner: *const InternPool.Global, id: TypeId, kind: Derived.Kind) u32 {
    const p = publishedContext(interfaces, types, interner, id, kind) orelse return 0;
    return p.iface.contextLen(p.row.context);
}

/// The method another module's derived function's `k`th evidence parameter
/// answers.
fn publishedMethod(interfaces: []const Interface, types: *const Types, interner: *const InternPool.Global, id: TypeId, kind: Derived.Kind, k: usize) ?Symbol {
    const p = publishedContext(interfaces, types, interner, id, kind) orelse return null;
    const e = p.iface.contextEntry(p.row.context, k) orelse return null;
    return p.iface.symbol(e.method);
}

/// How many evidence arguments the function a term names takes (I7):
/// `DeclInfo` for a value of this module, the interface scheme for an
/// imported one, the context for a derived function and, for another
/// module's derived function, its published context's length (§14.2).
/// Every other term takes none.
///
/// **The one counting function.** `checkI7` and `Lower`'s cheap
/// re-assert both call it; nothing else counts evidence.
pub fn requirementCount(d: *const Dispatch, t: Term, interfaces: []const Interface, types: *const Types, interner: *const InternPool.Global) u32 {
    return switch (t) {
        .top => |u| @intCast(d.declRequirements(u.decl.int()).len),
        .ext => |u| extRequirementCount(interfaces, u.module, @intFromEnum(u.value)),
        .derived => |u| @intCast(d.contextOf(u.index).len),
        .ext_derived => |u| publishedCount(interfaces, types, interner, u.type, u.kind),
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
/// A PREDICATE over the table, with nothing reported: its caller
/// turns each instruction into one `internal`, never a panic (S10).
pub fn checkI7(
    d: *const Dispatch,
    bir: *const Bir,
    interfaces: []const Interface,
    types: *const Types,
    interner: *const InternPool.Global,
    gpa: Allocator,
    out: *std.ArrayList(Bir.Inst.Index),
) Allocator.Error!void {
    var cx: I7 = .{ .d = d, .interfaces = interfaces, .types = types, .interner = interner };
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
/// `k`th requirement of the function it names (a derived function's, its
/// context entry's method), or null when the owner names none.
fn slotMethod(cx: I7, owner: Term, k: usize) ?Symbol {
    const d = cx.d;
    const interfaces = cx.interfaces;
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
        .ext_derived => |u| return publishedMethod(interfaces, cx.types, cx.interner, u.type, u.kind, k),
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
    interner: *const InternPool.Global,
    /// Per term: it and everything below it add up (`localOk`).
    below: []const bool = &.{},

    fn count(cx: I7, t: Term) u32 {
        return requirementCount(cx.d, t, cx.interfaces, cx.types, cx.interner);
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
                const method: Symbol.Optional = if (owner) |o| (if (slotMethod(cx, o, k)) |m| m.toOptional() else .none) else .none;
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
                const method: Symbol.Optional = if (slotMethod(cx, t, k)) |m| m.toOptional() else .none;
                try stack.append(gpa, .{ .term = arg.int(), .ctx = ctx, .method = method });
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
/// The tables these tests build name no other module, so nothing looks a
/// published row up (`publishedContext`) and the interner is never read.
const no_interner: *const InternPool.Global = undefined;

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

test "the I7 assert refuses a hand-corrupted table and accepts the table it came from" {
    // checker-v2.md §13.1: I7 is asserted and its caller reports each
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

    // A correct table, written as the trees it is (R12 deleted v1's flat
    // builder, which these tests used to go through): the call passes
    // declaration 0 its one argument, which is itself `top 0` applied to a
    // primitive, and the method call's callee is a primitive.
    const requirements = [_]Requirement{.{ .quantified = 0, .var_name = .none, .method = @enumFromInt(1) }};
    const decls = [_]DeclInfo{.{ .requirements = .{ .start = 0, .len = 1 } }};
    var terms_buf = [_]Term{
        .{ .top = .{ .decl = @enumFromInt(0), .args = .{ .start = 1, .len = 1 } } },
        .{ .primitive = .strict_eq },
        .{ .primitive = .strict_eq },
    };
    var args_buf = [_]TermIndex{ @enumFromInt(0), @enumFromInt(1) };
    var sites_buf = [_]Site{
        .{ .inst = @enumFromInt(2), .evidence = .{ .start = 0, .len = 1 } },
        .{ .inst = @enumFromInt(3), .callee = @enumFromInt(2) },
    };
    var d: Dispatch = .empty;
    d.terms = &terms_buf;
    d.args = &args_buf;
    d.sites = &sites_buf;
    d.decls = &decls;
    d.requirements = &requirements;

    var types: Types = .empty;
    var bad: std.ArrayList(Bir.Inst.Index) = .empty;
    defer bad.deinit(testing.allocator);
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 0), bad.items.len);

    // 1. One argument too few: the nested `top 0` loses its argument.
    const roots = d.argsAt(d.sites[0].evidence);
    const nested = d.argsOfTerm(roots[0])[0];
    const terms = @constCast(d.terms);
    const saved = terms[nested.int()];
    terms[nested.int()] = .{ .top = .{ .decl = @enumFromInt(0) } };
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
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
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    args[arg_at] = saved_arg;
    bad.clearRetainingCapacity();

    // 3. A root too many: the call claims two roots for a one-requirement
    //    callee.
    const sites = @constCast(d.sites);
    sites[0].evidence.len += 1;
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    sites[0].evidence.len -= 1;
    bad.clearRetainingCapacity();

    // 4. A method call with no callee.
    const saved_callee = sites[1].callee;
    sites[1].callee = .none;
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    try testing.expectEqual(@as(u32, 3), bad.items[0].int());
    sites[1].callee = saved_callee;
    bad.clearRetainingCapacity();

    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
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
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 0), bad.items.len);

    // The shared term pointing back at an owner is still refused.
    args[3] = @enumFromInt(1);
    try d.checkI7(&tb.bir, &.{}, &types, no_interner, testing.allocator, &bad);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
    try testing.expectEqual(@as(u32, 2), bad.items[0].int());
}
